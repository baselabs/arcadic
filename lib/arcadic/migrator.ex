defmodule Arcadic.Migrator do
  @moduledoc """
  Runs `Arcadic.Migration`s in order and tracks applied versions in the
  `_arcadic_migrations` document type. Tenant-blind: it runs DDL/DML and records
  integer versions — no tenant, scope, or Ash concept. Assumes single-process,
  deploy-time execution (like every migration tool); it does not take an advisory
  lock, so do not run two migrators concurrently against one database.

  ## Crash recovery (the marker contract)

  ArcadeDB session transactions do NOT roll back DDL (live-probed 2026-10-15, v26.10.2:
  `begin → CREATE TYPE → INSERT → rollback` discards the row but keeps the type), so
  `up` + version-recording cannot be made atomic. Instead every migration attempt is
  bracketed by a durable marker row:

      up:   INSERT {version, status: "up_started"} → mod.up/1 → UPDATE status "done"
      down: UPDATE status "down_started"            → mod.down/1 → DELETE the row

  The marker is removed ONLY by successful finalization or an explicit `resolve/3` —
  NEVER by an error cleanup. An error return (or raise, or a lost connection) after
  any committed statement proves nothing about what was applied, so the marker stays
  and the next `migrate/2`/`rollback/3`/`reset/2`/`status/2` REFUSES with
  `{:error, %Arcadic.Error{reason: :interrupted_migration}}` (value-free — run
  `interrupted/1` to see which versions are stuck) instead of silently re-running a
  possibly half-applied migration. The operator inspects schema AND data (including
  outstanding follow-on work), then records the established outcome with
  `resolve(conn, version, :applied | :not_applied)`.

  Idempotent migrations (`IF NOT EXISTS` / `IF EXISTS`) remain RECOMMENDED — see
  `Arcadic.Migration`'s example — but the marker, not author discipline, is the
  safety mechanism.

  Rows written before this contract (no `status` property) read as `done` at read
  time — no backfill write; legacy databases migrate transparently.

  Every entry point rejects a session-scoped conn (value-free `ArgumentError`): the
  marker writes are autocommit by construction, and a caller's `transaction/3`
  rollback would discard the marker while keeping the DDL.
  """

  alias Arcadic.Conn

  @type_name "_arcadic_migrations"
  @started_statuses ["up_started", "down_started"]

  @doc "Run all pending migrations (up). Returns `{:ok, count_run}`."
  @spec migrate(Conn.t(), module()) :: {:ok, non_neg_integer()} | {:error, Exception.t() | term()}
  def migrate(%Conn{session_id: sid} = conn, registry) when is_atom(registry) do
    reject_session!(sid)

    with :ok <- ensure_type(conn),
         {:ok, state} <- read_state(conn),
         :ok <- refuse_if_interrupted(state) do
      run_up(conn, pending_migrations(registry.migrations(), state.applied), 0)
    end
  end

  @doc """
  Status of each registered migration: `{version, :up | :down}`, ascending. Refuses
  (`:interrupted_migration`) while an interrupted migration marker exists.
  """
  @spec status(Conn.t(), module()) ::
          {:ok, [{pos_integer(), :up | :down}]} | {:error, Exception.t()}
  def status(%Conn{session_id: sid} = conn, registry) when is_atom(registry) do
    reject_session!(sid)

    with :ok <- ensure_type(conn),
         {:ok, state} <- read_state(conn),
         :ok <- refuse_if_interrupted(state) do
      statuses =
        registry.migrations()
        |> Enum.sort_by(& &1.version())
        |> Enum.map(fn mod ->
          {mod.version(), if(mod.version() in state.applied, do: :up, else: :down)}
        end)

      {:ok, statuses}
    end
  end

  @doc "Registered migrations not yet applied, ascending by version (pure)."
  @spec pending_migrations([module()], [integer()]) :: [module()]
  def pending_migrations(mods, applied) do
    mods
    |> Enum.sort_by(& &1.version())
    |> Enum.reject(fn mod -> mod.version() in applied end)
  end

  @doc """
  The versions with an interrupted marker (`up_started`/`down_started`), ascending —
  the structured reader for a `:interrupted_migration` refusal (the refusal itself is
  value-free; this is where the stuck versions surface to the operator).
  """
  @spec interrupted(Conn.t()) :: {:ok, [integer()]} | {:error, Exception.t()}
  def interrupted(%Conn{session_id: sid} = conn) do
    reject_session!(sid)

    with :ok <- ensure_type(conn),
         {:ok, state} <- read_state(conn) do
      {:ok, Enum.sort(state.interrupted)}
    end
  end

  @doc """
  Record the operator's established outcome for an interrupted migration:
  `:applied` (the migration's effects are in — finalizes the marker as `done`) or
  `:not_applied` (nothing of it remains — deletes the tracking row). Direction-agnostic
  by design: reconciliation expresses the RESULTING applied/unapplied state, so both a
  crashed `up` that never landed and a crashed `down` that never reversed resolve the
  same way. Requires an existing interrupted marker and a verified (non-zero-row)
  transition; value-free errors.
  """
  @spec resolve(Conn.t(), integer(), :applied | :not_applied) :: :ok | {:error, Exception.t()}
  def resolve(%Conn{session_id: sid} = conn, version, outcome)
      when is_integer(version) and outcome in [:applied, :not_applied] do
    reject_session!(sid)

    with :ok <- ensure_type(conn),
         {:ok, state} <- read_state(conn),
         :ok <- require_interrupted(state, version) do
      case outcome do
        :applied ->
          tracked_count(conn, "UPDATE #{@type_name} SET status = :s WHERE version = :v", %{
            "v" => version,
            "s" => "done"
          })

        :not_applied ->
          tracked_count(conn, "DELETE FROM #{@type_name} WHERE version = :v", %{"v" => version})
      end
      |> verified_transition()
    end
  end

  # Total value-free fallback: an invalid version/outcome must RAISE, never match a
  # session-reject clause that returns :ok on a session-free conn (a silent no-op resolve).
  def resolve(%Conn{}, _version, _outcome),
    do: raise(ArgumentError, "resolve/3 requires an integer version and :applied | :not_applied")

  @doc "Roll back the last `n` applied migrations (down), newest first. Returns `{:ok, count}`."
  @spec rollback(Conn.t(), module(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, Exception.t() | term()}
  def rollback(%Conn{session_id: sid} = conn, registry, n \\ 1)
      when is_atom(registry) and is_integer(n) and n > 0 do
    reject_session!(sid)

    with :ok <- ensure_type(conn),
         {:ok, state} <- read_state(conn),
         :ok <- refuse_if_interrupted(state) do
      to_roll =
        registry.migrations()
        |> Enum.filter(fn mod -> mod.version() in state.applied end)
        |> Enum.sort_by(& &1.version(), :desc)
        |> Enum.take(n)

      run_down(conn, to_roll, 0)
    end
  end

  @doc "Roll back every applied migration, then migrate all. Returns `{:ok, migrated_count}`."
  @spec reset(Conn.t(), module()) :: {:ok, non_neg_integer()} | {:error, Exception.t() | term()}
  def reset(%Conn{session_id: sid} = conn, registry) when is_atom(registry) do
    reject_session!(sid)

    with :ok <- ensure_type(conn),
         {:ok, state} <- read_state(conn),
         :ok <- refuse_if_interrupted(state),
         {:ok, _} <- rollback(conn, registry, max(length(state.applied), 1)) do
      migrate(conn, registry)
    end
  end

  defp run_up(_conn, [], count), do: {:ok, count}

  defp run_up(conn, [mod | rest], count) do
    with :ok <- mark_started(conn, mod.version(), "up_started"),
         :ok <- mod.up(conn),
         :ok <- finalize(conn, mod.version()) do
      run_up(conn, rest, count + 1)
    end
  end

  defp run_down(_conn, [], count), do: {:ok, count}

  defp run_down(conn, [mod | rest], count) do
    # The down marker transition must be VERIFIED (a positive integer row count) before any
    # destructive work — a zero-row or malformed response means the marker never landed, and
    # running `down` anyway would lose the crash-recovery guarantee.
    with {:ok, _} = ok <- mark_down_started(conn, mod.version()),
         :ok <- verified_transition(ok),
         :ok <- mod.down(conn),
         :ok <- delete_version(conn, mod.version()) do
      run_down(conn, rest, count + 1)
    end
  end

  # The marker INSERT is durably committed BEFORE mod.up runs: whatever happens next
  # (error return, raise, process death, lost connection), the attempt is recorded and
  # the next run refuses. There is deliberately NO cleanup on the error paths — an
  # error return proves nothing about what the server already committed.
  defp mark_started(conn, version, status) do
    tracked(
      conn,
      "INSERT INTO #{@type_name} SET version = :v, status = :s, applied_at = sysdate()",
      %{
        "v" => version,
        "s" => status
      }
    )
  end

  # The down marker TRANSITIONS the existing done row (never INSERTs a second one — a
  # failed down must leave exactly ONE row for the version, resolvable either way).
  defp mark_down_started(conn, version) do
    tracked_count(conn, "UPDATE #{@type_name} SET status = :s WHERE version = :v", %{
      "v" => version,
      "s" => "down_started"
    })
  end

  defp finalize(conn, version) do
    tracked(conn, "UPDATE #{@type_name} SET status = :s WHERE version = :v", %{
      "v" => version,
      "s" => "done"
    })
  end

  defp delete_version(conn, version) do
    tracked(conn, "DELETE FROM #{@type_name} WHERE version = :v", %{"v" => version})
  end

  defp ensure_type(conn) do
    tracked(conn, "CREATE DOCUMENT TYPE #{@type_name} IF NOT EXISTS")
  end

  # One shared reader for every entry point: applied = `status = "done"` OR no status
  # property (legacy pre-marker rows, interpreted at read time — never a backfill
  # write); interrupted = a started marker. Explicit interrupted states never receive
  # the legacy default.
  defp read_state(conn) do
    case Arcadic.command(conn, "SELECT version, status FROM #{@type_name} ORDER BY version", %{},
           language: "sql"
         ) do
      {:ok, rows} ->
        applied = for row <- rows, row["status"] in ["done", nil], do: row["version"]
        interrupted = for row <- rows, row["status"] in @started_statuses, do: row["version"]
        {:ok, %{applied: applied, interrupted: interrupted}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp refuse_if_interrupted(%{interrupted: []}), do: :ok

  defp refuse_if_interrupted(%{interrupted: [_ | _]}),
    do: {:error, interrupted_error()}

  defp require_interrupted(%{interrupted: versions}, version),
    do: if(version in versions, do: :ok, else: {:error, not_interrupted_error()})

  defp not_interrupted_error,
    do: %Arcadic.Error{reason: :invalid_state, message: "no interrupted marker for that version"}

  defp interrupted_error,
    do: %Arcadic.Error{
      reason: :interrupted_migration,
      message:
        "an interrupted migration is recorded — inspect schema and data, then Migrator.resolve/3 before migrating (Migrator.interrupted/1 lists them)"
    }

  # A transition that touched zero rows is a FAILURE, not a silent success — resolve
  # must not claim an outcome it did not record.
  defp verified_transition({:ok, n}) when is_integer(n) and n > 0, do: :ok

  defp verified_transition({:ok, _}),
    do: {:error, %Arcadic.Error{reason: :invalid_state, message: "transition matched no rows"}}

  defp verified_transition({:error, _} = err), do: err

  # @type_name is a fixed literal, never user input — safe to interpolate.
  defp tracked(conn, sql, params \\ %{}) do
    case Arcadic.command(conn, sql, params, language: "sql") do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  # Like tracked/3 but returns the affected-row count (an UPDATE/DELETE result row's
  # "count"), so a transition can be VERIFIED rather than assumed.
  defp tracked_count(conn, sql, params) do
    case Arcadic.command(conn, sql, params, language: "sql") do
      {:ok, [row | _]} when is_map(row) -> {:ok, row["count"] || 0}
      {:ok, _} -> {:ok, 0}
      {:error, error} -> {:error, error}
    end
  end

  defp reject_session!(nil), do: :ok

  defp reject_session!(_sid),
    do: raise(ArgumentError, "migrator requires a session-free conn (autocommit marker writes)")
end
