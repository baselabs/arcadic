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

  alias Arcadic.{Conn, Telemetry}

  @language_allowlist ~w(cypher sql sqlscript gremlin graphql mongo)
  @command_opts ~w(language limit serializer timeout retries)a
  @query_opts ~w(language limit serializer timeout)a

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

  defp validate_opts!(opts, allowed) do
    if language = opts[:language], do: validate_language!(language)

    case Keyword.keys(opts) -- allowed do
      [] ->
        opts

      bad ->
        raise ArgumentError, "unknown option(s) #{inspect(bad)}; allowed: #{inspect(allowed)}"
    end
  end

  defp validate_language!(language) when language in @language_allowlist, do: :ok

  defp validate_language!(language),
    do:
      raise(
        ArgumentError,
        "unknown language #{inspect(language)}; allowed: #{inspect(@language_allowlist)}"
      )
end
