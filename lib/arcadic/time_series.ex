defmodule Arcadic.TimeSeries do
  @moduledoc """
  ArcadeDB time-series — tenant-blind client for the `/api/v1/ts/<db>` wire family (InfluxDB
  line-protocol write, JSON query/latest, PromQL reads) plus the `TIMESERIES` DDL, downsampling
  policies, and continuous aggregates. Requires ArcadeDB >= 26.7.2 (older servers answer the
  `/ts` routes with a plain 404 `%Arcadic.Error{http_status: 404}`).

  DDL and continuous-aggregate statements ride `Arcadic.command/4` (`language: "sql"` — SQL-only
  over Bolt, like `Arcadic.Schema`). The wire family rides optional transport callbacks
  implemented by the HTTP transport only; on any other transport those functions return
  `{:error, %Arcadic.Error{reason: :not_supported}}`.

  Identifiers (type/column/tag/field names) are `Arcadic.Identifier`-validated; grammar tokens
  (column types, duration units, precisions, aggregation functions) are positive-allowlisted.
  The two rejection channels differ: an invalid identifier returns `{:error, :invalid_identifier}`,
  while an invalid opt value (column-type token, duration, precision, shard count) raises a
  value-free `ArgumentError`. Point values are DATA (line protocol / JSON / URL params), never
  statement text.

  ## Operational contract — write path (each clause live-probed on 26.7.2)

  - **Append-only, non-idempotent.** No dedup, no upsert, no server-assigned id: the identical
    point written twice is TWO rows. A lost response followed by a naive retry **duplicates every
    point in the body** (the same non-confirmability class as `Arcadic.Bulk.ingest/3`).
  - **Mixed-body partial swallow.** When at least one line's type exists, lines naming an UNKNOWN
    type are **silently dropped** (HTTP 204). The loud 400 `Unknown timeseries type(s)` fires only
    when every line's type is unknown. `write/3` guarantees syntactic validity by construction,
    but cannot know server type existence (tenant-blind, no schema cache) — a typo'd `type:` in a
    mixed batch is silent. Verify with `query/3` or `Arcadic.Schema.types/1` when it matters.
  - **Unknown FIELD zero-fill.** A line whose field name is not on the type inserts a
    **zero-filled row** (204, no error).
  - **Unknown tag KEY fails open** on `query/3`/`latest/3` (the filter is ignored server-side).
  - `write_lines/3` (raw passthrough) additionally inherits the malformed-line silent-skip.
  """

  alias Arcadic.{Conn, Identifier, Opts}

  @typedoc "A duration for `:retention` / `:compaction_interval` / downsampling opts."
  @type duration :: {pos_integer(), :seconds | :minutes | :hours | :days}

  # Column-type tokens accepted by CREATE TIMESERIES TYPE on 26.7.2 — every token live-probed
  # (spec S1 + plan-write probe). Positive allowlist: the token is interpolated into DDL.
  @column_types ~w(STRING INTEGER LONG DOUBLE BOOLEAN DATETIME FLOAT SHORT BYTE DECIMAL DATE BINARY LIST MAP EMBEDDED)
  # Plural-only in the CREATE clauses (singular parse-errors — probed); safe for downsampling
  # GRANULARITY too (its grammar accepts both).
  @duration_units %{seconds: "SECONDS", minutes: "MINUTES", hours: "HOURS", days: "DAYS"}
  @ddl_precisions %{
    second: "SECOND",
    millisecond: "MILLISECOND",
    microsecond: "MICROSECOND",
    nanosecond: "NANOSECOND"
  }

  @create_type_opts [:fields, :tags, :precision, :shards, :retention, :compaction_interval]
  @downsampling_opts [:after, :granularity]

  @doc """
  Creates a TIMESERIES type: `CREATE TIMESERIES TYPE name TIMESTAMP timestamp_col …`.

  ## Options
    * `:fields` — REQUIRED non-empty `[{name, type}]` (keyword or `{binary, binary}` pairs).
    * `:tags` — `[{name, type}]`, default none (a tagless type is valid — probed).
    * `:precision` — `:second | :millisecond | :microsecond | :nanosecond` (omit → server default
      NANOSECOND).
    * `:shards` — pos_integer.
    * `:retention` / `:compaction_interval` — `t:duration/0`.

  Clause order is the grammar's FIXED order (SHARDS → RETENTION → COMPACTION_INTERVAL); units
  emit as plural tokens. There is no `IF NOT EXISTS` (absent from the 26.7.2 grammar) — creating
  an existing type is a server error. Value-free on any invalid name/token/option.
  """
  @spec create_type(Conn.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, atom() | Exception.t()}
  def create_type(%Conn{} = conn, name, timestamp_col, opts \\ []) do
    Opts.validate_keys!(opts, @create_type_opts)
    fields = columns!(Keyword.get(opts, :fields, []), "at least one field is required")
    tags = optional_columns!(Keyword.get(opts, :tags, []))

    with {:ok, [name_ok, ts_ok]} <- validate_idents([name, timestamp_col]),
         {:ok, tag_cols} <- column_clauses(tags),
         {:ok, field_cols} <- column_clauses(fields) do
      statement =
        "CREATE TIMESERIES TYPE #{name_ok} TIMESTAMP #{ts_ok}" <>
          precision_clause(opts[:precision]) <>
          tags_clause(tag_cols) <>
          " FIELDS (#{Enum.join(field_cols, ", ")})" <>
          shards_clause(opts[:shards]) <>
          duration_clause("RETENTION", opts[:retention]) <>
          duration_clause("COMPACTION_INTERVAL", opts[:compaction_interval])

      command_ok(conn, statement)
    end
  end

  @doc "Creates a TIMESERIES type, raising on error."
  @spec create_type!(Conn.t(), String.t(), String.t(), keyword()) :: :ok
  def create_type!(%Conn{} = conn, name, timestamp_col, opts \\ []),
    do: bang(create_type(conn, name, timestamp_col, opts))

  @doc """
  Drops a TIMESERIES type (`DROP TIMESERIES TYPE name` — no `IF EXISTS`; dropping a missing type
  is a server error, mirroring `Arcadic.Trigger`/`Arcadic.MaterializedView`).
  """
  @spec drop_type(Conn.t(), String.t()) :: :ok | {:error, atom() | Exception.t()}
  def drop_type(%Conn{} = conn, name) do
    with {:ok, [name_ok]} <- validate_idents([name]) do
      command_ok(conn, "DROP TIMESERIES TYPE #{name_ok}")
    end
  end

  @doc "Drops a TIMESERIES type, raising on error."
  @spec drop_type!(Conn.t(), String.t()) :: :ok
  def drop_type!(%Conn{} = conn, name), do: bang(drop_type(conn, name))

  @doc """
  Adds a downsampling policy: `ALTER TIMESERIES TYPE type ADD DOWNSAMPLING POLICY AFTER n UNIT
  GRANULARITY n UNIT`. Both `:after` and `:granularity` are REQUIRED `t:duration/0`s.
  """
  @spec add_downsampling(Conn.t(), String.t(), keyword()) ::
          :ok | {:error, atom() | Exception.t()}
  def add_downsampling(%Conn{} = conn, type, opts) do
    Opts.validate_keys!(opts, @downsampling_opts)
    after_sql = required_duration!(opts, :after)
    gran_sql = required_duration!(opts, :granularity)

    with {:ok, [type_ok]} <- validate_idents([type]) do
      command_ok(
        conn,
        "ALTER TIMESERIES TYPE #{type_ok} ADD DOWNSAMPLING POLICY " <>
          "AFTER #{after_sql} GRANULARITY #{gran_sql}"
      )
    end
  end

  @doc "Adds a downsampling policy, raising on error."
  @spec add_downsampling!(Conn.t(), String.t(), keyword()) :: :ok
  def add_downsampling!(%Conn{} = conn, type, opts), do: bang(add_downsampling(conn, type, opts))

  @doc "Drops the type's downsampling policy (`ALTER TIMESERIES TYPE type DROP DOWNSAMPLING POLICY`)."
  @spec drop_downsampling(Conn.t(), String.t()) :: :ok | {:error, atom() | Exception.t()}
  def drop_downsampling(%Conn{} = conn, type) do
    with {:ok, [type_ok]} <- validate_idents([type]) do
      command_ok(conn, "ALTER TIMESERIES TYPE #{type_ok} DROP DOWNSAMPLING POLICY")
    end
  end

  @doc "Drops the type's downsampling policy, raising on error."
  @spec drop_downsampling!(Conn.t(), String.t()) :: :ok
  def drop_downsampling!(%Conn{} = conn, type), do: bang(drop_downsampling(conn, type))

  @doc """
  Creates a continuous aggregate: `CREATE CONTINUOUS AGGREGATE name AS select_sql`. The SELECT
  rides through VERBATIM — the same injection rationale as `Arcadic.MaterializedView`: it is raw
  trailing SQL (not a quoted literal), and ArcadeDB's live-verified single-statement backstop
  makes a `;`-separated second statement a parse error. The result materializes as a document
  type readable via `SELECT FROM name`. Refresh with `refresh_aggregate/2`.
  """
  @spec create_aggregate(Conn.t(), String.t(), String.t()) ::
          :ok | {:error, atom() | Exception.t()}
  def create_aggregate(%Conn{} = conn, name, select_sql) when is_binary(select_sql) do
    with {:ok, [name_ok]} <- validate_idents([name]) do
      command_ok(conn, "CREATE CONTINUOUS AGGREGATE #{name_ok} AS #{select_sql}")
    end
  end

  # A non-binary select must not FunctionClauseError (blame echoes the args — Rule 3).
  # Fully open fallback (no %Conn{} match), mirroring Arcadic.MaterializedView.create/3:
  # a restrictive head with no total fallback IS the FunctionClauseError leak.
  def create_aggregate(_conn, _name, _select_sql),
    do: raise(ArgumentError, "select must be a string")

  @doc "Creates a continuous aggregate, raising on error."
  @spec create_aggregate!(Conn.t(), String.t(), String.t()) :: :ok
  def create_aggregate!(%Conn{} = conn, name, select_sql),
    do: bang(create_aggregate(conn, name, select_sql))

  @doc "Refreshes a continuous aggregate (`REFRESH CONTINUOUS AGGREGATE name`)."
  @spec refresh_aggregate(Conn.t(), String.t()) :: :ok | {:error, atom() | Exception.t()}
  def refresh_aggregate(%Conn{} = conn, name) do
    with {:ok, [name_ok]} <- validate_idents([name]) do
      command_ok(conn, "REFRESH CONTINUOUS AGGREGATE #{name_ok}")
    end
  end

  @doc "Refreshes a continuous aggregate, raising on error."
  @spec refresh_aggregate!(Conn.t(), String.t()) :: :ok
  def refresh_aggregate!(%Conn{} = conn, name), do: bang(refresh_aggregate(conn, name))

  @doc "Drops a continuous aggregate (no `IF EXISTS` — a missing aggregate is a server error)."
  @spec drop_aggregate(Conn.t(), String.t()) :: :ok | {:error, atom() | Exception.t()}
  def drop_aggregate(%Conn{} = conn, name) do
    with {:ok, [name_ok]} <- validate_idents([name]) do
      command_ok(conn, "DROP CONTINUOUS AGGREGATE #{name_ok}")
    end
  end

  @doc "Drops a continuous aggregate, raising on error."
  @spec drop_aggregate!(Conn.t(), String.t()) :: :ok
  def drop_aggregate!(%Conn{} = conn, name), do: bang(drop_aggregate(conn, name))

  # --- private: DDL assembly ---

  # :fields must be present and non-empty; :tags may be absent. Both normalize to
  # [{binary_name, binary_type}] with atom keys allowed. Static messages only (Rule 3).
  defp columns!(cols, empty_msg) do
    case normalize_columns!(cols) do
      [] -> raise ArgumentError, empty_msg
      list -> list
    end
  end

  defp optional_columns!(cols), do: normalize_columns!(cols)

  defp normalize_columns!(cols) when is_list(cols) do
    Enum.map(cols, fn
      {k, v} when (is_atom(k) or is_binary(k)) and is_binary(v) -> {to_string(k), v}
      _ -> raise ArgumentError, "columns must be {name, type} pairs with a string type"
    end)
  end

  defp normalize_columns!(_),
    do: raise(ArgumentError, "columns must be a list of {name, type} pairs")

  # Validates every column name (identifier) and its TYPE token (positive allowlist — the token
  # is interpolated into DDL; an off-list token raises value-free, never echoing the input).
  defp column_clauses(cols) do
    Enum.reduce_while(cols, {:ok, []}, fn {col_name, col_type}, {:ok, acc} ->
      cond do
        Identifier.validate(col_name) != :ok -> {:halt, {:error, :invalid_identifier}}
        col_type not in @column_types -> {:halt, :bad_type}
        true -> {:cont, {:ok, ["#{col_name} #{col_type}" | acc]}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
      :bad_type -> raise ArgumentError, "unknown column type; allowed: #{inspect(@column_types)}"
    end
  end

  defp validate_idents(list) do
    Enum.reduce_while(list, {:ok, []}, fn ident, {:ok, acc} ->
      case Identifier.validate(ident) do
        :ok -> {:cont, {:ok, [ident | acc]}}
        {:error, :invalid_identifier} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end

  defp precision_clause(nil), do: ""

  defp precision_clause(p) do
    case Map.fetch(@ddl_precisions, p) do
      {:ok, token} ->
        " PRECISION #{token}"

      :error ->
        raise ArgumentError, "unknown precision; allowed: #{inspect(Map.keys(@ddl_precisions))}"
    end
  end

  defp tags_clause([]), do: ""
  defp tags_clause(cols), do: " TAGS (#{Enum.join(cols, ", ")})"

  defp shards_clause(nil), do: ""
  defp shards_clause(n) when is_integer(n) and n > 0, do: " SHARDS #{n}"
  defp shards_clause(_), do: raise(ArgumentError, "shards must be a positive integer")

  defp duration_clause(_kw, nil), do: ""
  defp duration_clause(kw, duration), do: " #{kw} #{duration_sql!(duration)}"

  defp duration_sql!({n, unit})
       when is_integer(n) and n > 0 and is_map_key(@duration_units, unit),
       do: "#{n} #{@duration_units[unit]}"

  defp duration_sql!(_),
    do:
      raise(
        ArgumentError,
        "duration must be {pos_integer, unit}; units: #{inspect(Map.keys(@duration_units))}"
      )

  defp required_duration!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, d} -> duration_sql!(d)
      :error -> raise ArgumentError, "#{key} is required"
    end
  end

  defp command_ok(conn, statement) do
    case Arcadic.command(conn, statement, %{}, language: "sql") do
      {:ok, _rows} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  # Shared bang: :ok passthrough; {:ok, value} unwrap (consumed by query!/latest!/prom_*! in
  # later tasks — NOT dead code); exceptions reraise; bare atoms get a static message.
  # A hidden-public `def` (not `defp`): every caller at THIS commit returns `:ok | {:error, _}`,
  # so dialyzer call-site-narrows a private bang/1 and flags the `{:ok, value}` clause as
  # unmatchable (pattern_match). Exporting it keeps the forward-consumed clause verbatim with
  # dialyzer green — no ignore file, no `@dialyzer` suppression (the changes.ex convention) —
  # and the `@doc false` below keeps it off the hexdocs API surface.
  @doc false
  def bang(:ok), do: :ok
  def bang({:ok, value}), do: value
  def bang({:error, %{__exception__: true} = error}), do: raise(error)

  def bang({:error, reason}),
    do: raise(ArgumentError, "time-series operation failed: #{inspect(reason)}")
end
