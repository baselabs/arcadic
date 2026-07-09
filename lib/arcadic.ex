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

  All dynamic values reach ArcadeDB **only as bound parameters** — `$name` for
  Cypher, `:name` for SQL (the `language:` opt selects the dialect) — never string
  interpolation. Use `explain/4`/`profile/4` to inspect a statement's execution
  plan without guessing: `explain` is plan-only, `profile` executes the
  statement (a write mutates).
  """

  alias Arcadic.{Conn, Opts, Telemetry}

  @language_allowlist ~w(cypher sql sqlscript gremlin graphql mongo)
  @command_opts ~w(language limit serializer timeout retries)a
  @query_opts ~w(language limit serializer timeout)a
  @query_stream_opts ~w(chunk_size timeout language order_key)a
  # explain/profile take only :language + :timeout. retries is EXCLUDED — PROFILE executes, so a
  # retry double-runs the write; limit/serializer are meaningless for a plan.
  @explain_opts ~w(language timeout)a
  @profile_opts ~w(language timeout)a

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
    validate_params!(params)
    language = opts[:language] || "cypher"
    request = %{statement: statement, params: params, language: language}

    Telemetry.span(:command, %{language: language, mode: :write, async?: true}, fn ->
      result = run_async(conn, request, opts)
      {result, %{reason: async_reason(result)}}
    end)
  end

  @doc """
  Return the execution plan for a statement WITHOUT running it: prepends `EXPLAIN `
  and returns `{:ok, %{plan: <human string>, plan_tree: <raw, transport-defined map>,
  rows: []}}`.

  EXPLAIN is plan-only and side-effect-free (portable across read/write statements);
  its telemetry span is read-labeled (`mode: :read`). Takes only `:language` (default `"cypher"`) and
  `:timeout`; `:retries`/`:limit`/`:serializer` are rejected value-free (a plan is
  not a paged, retried, or serialized row set). Returns
  `{:error, %Arcadic.Error{reason: :not_supported}}` when the active transport does
  not implement `explain/3`.
  """
  @spec explain(Conn.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, Exception.t()}
  def explain(%Conn{} = conn, statement, params \\ %{}, opts \\ []) do
    validate_statement!(statement)
    run_explain(conn, :read, "EXPLAIN " <> statement, params, validate_opts!(opts, @explain_opts))
  end

  @doc "Like `explain/4` but returns the plan map or raises."
  @spec explain!(Conn.t(), String.t(), map(), keyword()) :: map()
  def explain!(%Conn{} = conn, statement, params \\ %{}, opts \\ []),
    do: bang_plan(explain(conn, statement, params, opts))

  @doc """
  Profile a statement by EXECUTING it, returning its plan annotated with real runtime
  metrics: prepends `PROFILE ` and returns `{:ok, %{plan: <human string>,
  plan_tree: <raw, transport-defined map>, rows: <executed rows>}}`.

  **PROFILE runs the statement** — a write mutates — so it routes the write path and
  its telemetry span carries `in_transaction?` (like `command/4`). Takes only
  `:language` (default `"cypher"`) and `:timeout`; `:retries` is EXCLUDED (a retry
  would double-run the write) and `:limit`/`:serializer` are meaningless for a plan —
  all rejected value-free. Returns `{:error, %Arcadic.Error{reason: :not_supported}}`
  when the active transport does not implement `explain/3`.
  """
  @spec profile(Conn.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, Exception.t()}
  def profile(%Conn{} = conn, statement, params \\ %{}, opts \\ []) do
    validate_statement!(statement)

    run_explain(
      conn,
      :write,
      "PROFILE " <> statement,
      params,
      validate_opts!(opts, @profile_opts)
    )
  end

  @doc "Like `profile/4` but returns the plan map or raises."
  @spec profile!(Conn.t(), String.t(), map(), keyword()) :: map()
  def profile!(%Conn{} = conn, statement, params \\ %{}, opts \\ []),
    do: bang_plan(profile(conn, statement, params, opts))

  @doc """
  Lazily stream a large read result as raw row maps. Returns `{:ok, Stream.t()}` or
  `{:error, Arcadic.Error.t()}` if the statement/opts don't fit the active
  transport's streaming contract.

  `:chunk_size` (rows per round-trip, default 1000) must be a positive integer, else a
  value-free `ArgumentError`.

  **HTTP** (the default transport): pages the statement itself behind the scenes via an
  arcadic-owned paging suffix — an O(n) `@rid` keyset for WHERE-less SQL, offset otherwise
  (see "The streamable statement class" below). `@rid`/`id(<identifier>)` is a total ORDER,
  so a page is stably ordered, but each page is an independent stateless request — it is NOT
  a consistent snapshot, so a concurrent write can change which rows a later page sees (the
  offset path can skip an already-emitted row on a concurrent delete; the keyset path avoids
  that offset-shift but is still not a snapshot); use a Bolt in-tx cursor when you need
  snapshot consistency. A statement carrying its own `ORDER BY`/`SKIP`/`LIMIT`,
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
  ORDER BY @rid LIMIT` — which is O(n) and free of the offset-shift skip a concurrent delete causes on
  the offset path (though still not a snapshot); a statement with its own `WHERE` falls back to
  `ORDER BY @rid SKIP/LIMIT` offset (O(n²), arcadic cannot inject a keyset predicate without parsing).
  Because `@rid` is arcadic's SQL paging column, a streamed SQL statement must not alias an output
  column to `@rid` (a rebind would silently mis-page) — rejected value-free. **Cypher** requires
  `:order_key` (e.g. `order_key: "id(v)"`), restricted
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
    validate_params!(params)

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
    validate_params!(params)
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

  # explain/profile dispatch to the OPTIONAL transport `explain/3` callback (guarded by
  # function_exported?, like query_stream/4) — a transport without it gets a typed
  # `:not_supported`, never an UndefinedFunctionError. The span dispatch is extracted to
  # dispatch_explain/5 so neither the guard nor the span nests too deep (credo max-depth 2).
  defp run_explain(conn, mode, statement, params, opts) do
    validate_params!(params)

    if Code.ensure_loaded?(conn.transport) and function_exported?(conn.transport, :explain, 3) do
      dispatch_explain(conn, mode, statement, params, opts)
    else
      {:error,
       %Arcadic.Error{
         reason: :not_supported,
         message: "transport does not support explain/profile"
       }}
    end
  end

  # The `:explain` span mirrors run/5: start_meta from explain_meta/3, stop_meta carries
  # reason + row_count of the executed rows (0 for EXPLAIN's plan-only result).
  defp dispatch_explain(conn, mode, statement, params, opts) do
    language = opts[:language] || "cypher"
    request = %{statement: statement, params: params, language: language}

    Telemetry.span(:explain, explain_meta(mode, language, conn), fn ->
      case conn.transport.explain(conn, request, opts) do
        {:ok, plan} = ok -> {ok, %{http_status: 200, reason: :ok, row_count: length(plan.rows)}}
        {:error, err} = error -> {error, %{reason: reason_of(err)}}
      end
    end)
  end

  # EXPLAIN is plan-only → read span; PROFILE executes → write span carrying `in_transaction?`
  # (spec §10 telemetry table), mirroring start_meta/3 for command/4.
  defp explain_meta(:read, language, _conn), do: %{language: language, mode: :read}

  defp explain_meta(:write, language, conn),
    do: %{language: language, mode: :write, in_transaction?: not is_nil(conn.session_id)}

  defp bang_plan({:ok, plan}), do: plan
  defp bang_plan({:error, error}), do: raise(error)

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

  # `params` must be a map before it reaches the transport — downstream `Map.has_key?/2` (the reserved
  # paging guard) and `map_size/1` (`build_body`) raise a `BadMapError` that echoes the whole value, so
  # a caller passing a keyword list (a natural mistake — `opts` IS a keyword list) would leak its values
  # into the message (Rule 3). Reject value-free at the facade instead. `nil` is not a valid params.
  defp validate_params!(params) when is_map(params), do: :ok
  defp validate_params!(_), do: raise(ArgumentError, "params must be a map")

  # `statement` must be a binary BEFORE the `EXPLAIN `/`PROFILE ` keyword is prepended — a non-binary
  # term makes the `<>` concat raise `construction of binary failed ... got: <value>`, echoing the
  # whole term into the message (the Rule-3 leak class validate_params!/1 already guards for `opts`).
  # Reject value-free at the explain/profile facade. query/command carry the statement through to the
  # transport body without a `<>`, so they never hit this raise path and need no guard here.
  defp validate_statement!(statement) when is_binary(statement), do: :ok
  defp validate_statement!(_), do: raise(ArgumentError, "statement must be a string")

  defp validate_language!(language) when language in @language_allowlist, do: :ok

  defp validate_language!(language),
    do:
      raise(
        ArgumentError,
        "unknown language #{inspect(language)}; allowed: #{inspect(@language_allowlist)}"
      )
end
