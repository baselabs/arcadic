defmodule Arcadic do
  @moduledoc """
  A lean, framework-agnostic Elixir client for [ArcadeDB](https://arcadedb.com)
  over the **HTTP Cypher command API**.

  Arcadic is the "`postgrex` of ArcadeDB": it ships Cypher/SQL, manages
  connections and session transactions, and normalizes responses — nothing more.
  It is deliberately **tenant-blind and framework-agnostic**. Multitenancy,
  classification, and Ash resources live one layer up, in `ash_arcadic`.

      conn = Arcadic.connect("http://localhost:2480", "mydb", auth: {"root", pass})
      {:ok, rows} = Arcadic.query(conn, "MATCH (n:User) RETURN n LIMIT $lim", %{"lim" => 10})
      {:ok, [user]} = Arcadic.command(conn, "CREATE (u:User {name:$n}) RETURN u", %{"n" => "Jo"})

      {:ok, result} = Arcadic.transaction(conn, fn tx ->
        Arcadic.command!(tx, "MERGE (u:User {id:$id})", %{"id" => "u1"})
      end)

  All dynamic values reach ArcadeDB **only as bound parameters** (`$name`), never
  string interpolation.
  """

  alias Arcadic.{Conn, Opts, Telemetry}

  @language_allowlist ~w(cypher sql sqlscript gremlin graphql mongo)
  @command_opts ~w(language limit serializer timeout retries)a
  @query_opts ~w(language limit serializer timeout)a
  @query_stream_opts ~w(chunk_size timeout language order_key)a

  @doc "Build a connection handle. See `Arcadic.Conn.new/3`."
  @spec connect(String.t(), String.t(), keyword()) :: Conn.t()
  defdelegate connect(base_url, database, opts \\ []), to: Conn, as: :new

  @doc "Derive a same-pool handle on another database. See `Arcadic.Conn.with_database/2`."
  @spec with_database(Conn.t(), String.t()) :: Conn.t()
  defdelegate with_database(conn, database), to: Conn

  @doc """
  Run a read statement (`POST /api/v1/query`). The server rejects non-idempotent
  statements. Returns `{:ok, rows}` or `{:error, Arcadic.Error.t() | Arcadic.TransportError.t()}`.
  """
  @spec query(Conn.t(), String.t(), map(), keyword()) :: {:ok, [map()]} | {:error, Exception.t()}
  def query(%Conn{} = conn, statement, params \\ %{}, opts \\ []) do
    run(conn, :read, statement, params, validate_opts!(opts, @query_opts))
  end

  @doc "Run a read statement, returning the rows or raising."
  @spec query!(Conn.t(), String.t(), map(), keyword()) :: [map()]
  def query!(%Conn{} = conn, statement, params \\ %{}, opts \\ []),
    do: bang(query(conn, statement, params, opts))

  @doc """
  Run a write statement (`POST /api/v1/command`). Returns `{:ok, rows}` or
  `{:error, Arcadic.Error.t() | Arcadic.TransportError.t()}`.
  """
  @spec command(Conn.t(), String.t(), map(), keyword()) ::
          {:ok, [map()]} | {:error, Exception.t()}
  def command(%Conn{} = conn, statement, params \\ %{}, opts \\ []) do
    run(conn, :write, statement, params, validate_opts!(opts, @command_opts))
  end

  @doc "Run a write statement, returning the rows or raising."
  @spec command!(Conn.t(), String.t(), map(), keyword()) :: [map()]
  def command!(%Conn{} = conn, statement, params \\ %{}, opts \\ []),
    do: bang(command(conn, statement, params, opts))

  @doc """
  Fire-and-forget write: sends `awaitResponse: false`; the server enqueues and
  returns HTTP 202. Returns `:ok` on enqueue — the caller CANNOT confirm the write
  landed (that is the defined semantic; use `command/4` for confirmable writes).
  """
  @spec command_async(Conn.t(), String.t(), map(), keyword()) :: :ok | {:error, Exception.t()}
  def command_async(%Conn{} = conn, statement, params \\ %{}, opts \\ []) do
    opts = validate_opts!(opts, @command_opts)
    language = opts[:language] || "cypher"
    request = %{statement: statement, params: params, language: language}

    Telemetry.span(:command, %{language: language, mode: :write, async?: true}, fn ->
      result = run_async(conn, request, opts)
      {result, %{reason: async_reason(result)}}
    end)
  end

  @doc """
  Lazily stream a large read result as raw row maps. Returns `{:ok, Stream.t()}` or
  `{:error, Arcadic.Error.t()}` if the statement/opts don't fit the active
  transport's streaming contract.

  `:chunk_size` (rows per round-trip, default 1000) must be a positive integer, else a
  value-free `ArgumentError`.

  **HTTP** (the default transport): offset-pages the statement itself behind the scenes
  via an arcadic-owned, param-bound paging suffix. `@rid`/`id(<identifier>)` is a total
  ORDER (a page is stably ordered within one snapshot), but each page is an independent
  stateless request — it is NOT a consistent snapshot, so a concurrent delete of an
  already-emitted row can cause a later row to be skipped; use a Bolt in-tx cursor when
  you need snapshot consistency. A statement carrying its own `ORDER BY`/`SKIP`/`LIMIT`,
  a comment (`--`/`/*` for SQL, `//` for Cypher, which would neutralize the appended
  suffix), or a param named `__arcadic_skip`/`__arcadic_limit` (reserved), is rejected
  value-free (`reason: :not_supported`). `:timeout` bounds each page POST (default
  `:infinity` — a stream is long-running, so it does NOT inherit the conn's per-call
  timeout; set `:timeout` to bound a stalled server). Refuses inside a transaction
  (`reason: :not_supported`) — HTTP has no cursor to scope to a session.

  ## The streamable statement class (HTTP)

  A streamable HTTP statement carries NO `ORDER BY` / `SKIP` / `LIMIT` / comment anywhere (arcadic
  appends its own paging suffix; a caller clause or a `--`/`/*`/`//` comment would collide with or
  neutralize it, so each is rejected value-free). Roughly a bare `SELECT … FROM …` (SQL) or
  `MATCH … RETURN …` (Cypher).

  **SQL** pages by an arcadic-owned `@rid` keyset for a WHERE-less statement — `WHERE @rid > <cursor>
  ORDER BY @rid LIMIT` — which is O(n) and skips no row under concurrent inserts; a statement with its
  own `WHERE` falls back to `ORDER BY @rid SKIP/LIMIT` offset (O(n²), arcadic cannot inject a keyset
  predicate without parsing). **Cypher** requires `:order_key` (e.g. `order_key: "id(v)"`), restricted
  to `id(<identifier>)` — the only total, unique order — and pages by offset with Cypher `$name`
  placeholders; documents are Cypher-unmatchable, so stream them as SQL. HTTP streaming is stateless
  offset/keyset, not a consistent snapshot: for O(n) snapshot-consistent in-transaction Cypher
  streaming use the **Bolt** cursor (`transport: Arcadic.Transport.Bolt` inside `transaction/3`).

  **Bolt**: opens a dedicated connection for the stream's lifetime and pulls
  `:chunk_size` rows per round-trip (default 1000). Inside `transaction/3`, streams
  over the transaction's own connection instead (so it sees the transaction's own
  uncommitted writes), guarded so an `execute` on that conn cannot interleave an
  open cursor on the shared socket. **The in-transaction stream is lazy and bound to the
  transaction's connection — you MUST consume it (e.g. `Enum.to_list/1`) INSIDE the
  `transaction/3` body; enumerating the returned stream after `transaction/3` has returned
  fails (the connection is no longer checked out).** `:timeout` bounds each RUN and PULL
  receive (default `:infinity`; set it to bound a stalled server) — a breach raises
  `%Arcadic.TransportError{reason: :timeout}`. Any protocol error mid-stream RAISES
  a typed error; the connection is always torn down on completion, early halt, or
  error.
  """
  @spec query_stream(Conn.t(), String.t(), map(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Arcadic.Error.t()}
  def query_stream(%Conn{} = conn, statement, params \\ %{}, opts \\ []) do
    opts = validate_opts!(opts, @query_stream_opts)
    validate_chunk_size!(opts[:chunk_size])

    if Code.ensure_loaded?(conn.transport) and
         function_exported?(conn.transport, :query_stream, 3) do
      request = %{statement: statement, params: params, language: opts[:language] || "cypher"}
      conn.transport.query_stream(conn, request, opts)
    else
      {:error,
       %Arcadic.Error{reason: :not_supported, message: "transport does not support streaming"}}
    end
  end

  @doc "Run a function within a session transaction. See `Arcadic.Transaction.transaction/3`."
  @spec transaction(Conn.t(), (Conn.t() -> result), keyword()) :: {:ok, result} | {:error, term()}
        when result: var
  defdelegate transaction(conn, fun, opts \\ []), to: Arcadic.Transaction

  @doc "Roll back the current transaction with a reason. See `Arcadic.Transaction.rollback/2`."
  @spec rollback(Conn.t(), term()) :: no_return()
  defdelegate rollback(tx, reason), to: Arcadic.Transaction

  # ── internals ──────────────────────────────────────────────────────────────

  defp run(conn, mode, statement, params, opts) do
    language = opts[:language] || "cypher"
    request = %{statement: statement, params: params, language: language}
    op = if(mode == :read, do: :query, else: :command)

    Telemetry.span(op, start_meta(mode, language, conn), fn ->
      case conn.transport.execute(conn, mode, request, opts) do
        {:ok, rows} = ok -> {ok, %{http_status: 200, reason: :ok, row_count: length(rows)}}
        {:error, err} = error -> {error, %{reason: reason_of(err)}}
      end
    end)
  end

  # Command spans carry `in_transaction?` (spec §10 telemetry table); query spans do not.
  defp start_meta(:write, language, conn),
    do: %{language: language, mode: :write, in_transaction?: not is_nil(conn.session_id)}

  defp start_meta(mode, language, _conn), do: %{language: language, mode: mode}

  defp reason_of(%{reason: reason}), do: reason
  defp reason_of(_), do: :error

  # Async is an OPTIONAL transport capability — a transport without execute_async/3
  # (Bolt, a minimal mock) gets a typed error, never an UndefinedFunctionError.
  defp run_async(conn, request, opts) do
    if Code.ensure_loaded?(conn.transport) and
         function_exported?(conn.transport, :execute_async, 3) do
      conn.transport.execute_async(conn, request, opts)
    else
      {:error,
       %Arcadic.Error{reason: :not_supported, message: "transport does not support async writes"}}
    end
  end

  defp async_reason(:ok), do: :ok
  defp async_reason({:error, err}), do: reason_of(err)

  defp bang({:ok, rows}), do: rows
  defp bang({:error, error}), do: raise(error)

  # Key-shape + allowlist guard is delegated to the shared value-free `Arcadic.Opts.validate_keys!/2`
  # (which guards with `Keyword.keyword?/1` BEFORE `Keyword.keys/1` — an improper-list opts would
  # otherwise leak the offending entry through the raised message, AGENTS.md Rule 3). This module
  # layers its two extra concerns on top: validate the `:language` VALUE, and return `opts` for
  # inline threading.
  defp validate_opts!(opts, allowed) do
    Opts.validate_keys!(opts, allowed)
    if language = opts[:language], do: validate_language!(language)
    opts
  end

  # A non-positive chunk_size is a caller error, not a valid stream: on HTTP a `LIMIT 0` yields a
  # silently empty stream and a `LIMIT -1` (returns ALL rows, so `length < chunk` is never true)
  # walks the offset backwards forever re-emitting the whole result set; on Bolt a bad `PULL {n}`
  # is equally wrong. Reject value-free at the facade so both transports are normalized. `nil`
  # defers to each transport's default (1000).
  defp validate_chunk_size!(nil), do: :ok
  defp validate_chunk_size!(n) when is_integer(n) and n > 0, do: :ok

  defp validate_chunk_size!(_),
    do: raise(ArgumentError, "chunk_size must be a positive integer")

  defp validate_language!(language) when language in @language_allowlist, do: :ok

  defp validate_language!(language),
    do:
      raise(
        ArgumentError,
        "unknown language #{inspect(language)}; allowed: #{inspect(@language_allowlist)}"
      )
end
