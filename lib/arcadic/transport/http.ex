defmodule Arcadic.Transport.HTTP do
  @moduledoc """
  The HTTP Cypher transport (the only implementation of `Arcadic.Transport`).

  Reads go to `/api/v1/query/<db>` (server-enforced idempotent), writes to
  `/api/v1/command/<db>`. The `arcadedb-session-id` header is echoed on every
  request whenever `conn.session_id` is set, so reads and writes inside a
  transaction are session-scoped. Req's own client retry is disabled — retry
  semantics are the caller's (`retries:` body param) and the error taxonomy's.
  """

  @behaviour Arcadic.Transport

  alias Arcadic.{Conn, Error, Result, TransportError}

  @impl true
  def execute(%Conn{} = conn, mode, request, opts) when mode in [:read, :write] do
    path = "/api/v1/#{endpoint(mode)}/#{conn.database}"
    body = build_body(request, opts)

    conn
    |> post(path, body, opts)
    |> handle_result()
  end

  defp endpoint(:read), do: "query"
  defp endpoint(:write), do: "command"

  @paging_clause_re ~r/\b(order\s+by|skip|limit)\b/i
  # A SQL comment token in the caller statement is fail-closed too: a trailing `--` (line comment)
  # would comment OUT arcadic's appended ` ORDER BY @rid SKIP … LIMIT …` suffix, so the page runs
  # unpaged (full result set, HTTP 200) and `length(rows) < chunk` never trips — a silent-wrong,
  # non-terminating stream. `/*` (block comment) is rejected on the same principle.
  @comment_token_re ~r/(--|\/\*)/
  # arcadic OWNS these param names (it binds the offsets); a caller param of the same name would be
  # silently clobbered by Map.merge, mis-binding the caller's own predicate. Reserve them.
  @reserved_params ~w(__arcadic_skip __arcadic_limit)

  @impl true
  @spec query_stream(Conn.t(), Arcadic.Transport.request(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def query_stream(%Conn{session_id: sid}, _request, _opts) when is_binary(sid) do
    {:error,
     %Error{
       reason: :not_supported,
       message: "HTTP streaming is not available inside a transaction"
     }}
  end

  def query_stream(
        %Conn{} = conn,
        %{statement: statement, params: params, language: language},
        opts
      ) do
    cond do
      language != "sql" ->
        {:error,
         %Error{reason: :not_supported, message: "HTTP streaming requires language: \"sql\""}}

      Regex.match?(@paging_clause_re, statement) ->
        {:error,
         %Error{
           reason: :not_supported,
           message:
             "HTTP streaming statement must not contain ORDER BY / SKIP / LIMIT (arcadic pages by @rid)"
         }}

      Regex.match?(@comment_token_re, statement) ->
        {:error,
         %Error{
           reason: :not_supported,
           message:
             "HTTP streaming statement must not contain a SQL comment (-- or /*) — it would neutralize arcadic's paging suffix"
         }}

      Enum.any?(@reserved_params, &Map.has_key?(params, &1)) ->
        {:error,
         %Error{
           reason: :not_supported,
           message:
             "HTTP streaming reserves the params __arcadic_skip / __arcadic_limit (arcadic pages by @rid)"
         }}

      true ->
        chunk = Keyword.get(opts, :chunk_size, 1000)
        timeout = Keyword.get(opts, :timeout, :infinity)
        {:ok, build_page_stream(conn, statement, params, chunk, timeout)}
    end
  end

  # Offset paging: append arcadic's OWN fixed suffix; offsets ride params. `@rid` is a total
  # ORDER, so a page is stably positioned WITHIN a single snapshot — but each page is an
  # independent stateless POST (no session — in-tx refused), so a concurrent DELETE of an
  # already-emitted row shifts later rows down and the next `SKIP` can step over one (a row
  # silently missing). It is stable ordering, not a consistent snapshot; use a Bolt in-tx cursor
  # for snapshot consistency. ArcadeDB SQL binds `:name` placeholders, NOT `$name` (that is
  # Cypher's syntax); a `$`-named SQL param binds to null → `Invalid value for LIMIT: null`.
  defp build_page_stream(conn, statement, params, chunk, timeout) do
    paged = statement <> " ORDER BY @rid SKIP :__arcadic_skip LIMIT :__arcadic_limit"

    Stream.resource(
      fn -> 0 end,
      fn
        :done ->
          {:halt, :done}

        offset ->
          page_params =
            Map.merge(params, %{"__arcadic_skip" => offset, "__arcadic_limit" => chunk})

          emit_page(page(conn, paged, page_params, timeout), chunk, offset)
      end,
      fn _ -> :ok end
    )
  end

  # A full page (== chunk) advances the offset; a short/empty page is the last (drain).
  defp emit_page({:ok, []}, _chunk, _offset), do: {:halt, :done}

  defp emit_page({:ok, rows}, chunk, offset) do
    shaped = Enum.map(rows, &strip_order_alias/1)
    next = if length(rows) < chunk, do: :done, else: offset + chunk
    {shaped, next}
  end

  defp emit_page({:error, e}, _chunk, _offset), do: raise(e)

  # The body-level `limit` mirrors the statement's `LIMIT :__arcadic_limit` (== chunk). Without it,
  # ArcadeDB's DEFAULT body limit (20000) caps a page BELOW the statement LIMIT, and since a page
  # shorter than `chunk` is treated as the last, a `chunk_size` above the server default would
  # SILENTLY truncate the stream. Setting it to the chunk makes the statement LIMIT the only cap.
  defp page(conn, statement, params, timeout) do
    body = %{
      language: "sql",
      command: statement,
      params: params,
      limit: params["__arcadic_limit"]
    }

    conn
    |> post("/api/v1/query/#{conn.database}", body, timeout: timeout)
    |> handle_result()
  end

  # Appending `ORDER BY @rid` to a PROJECTION makes ArcadeDB inject a synthetic
  # `_$$$ORDER_BY_ALIAS$$$_N` ordering column (probed live) — drop it. `@props` is already
  # dropped by Result.normalize inside handle_result.
  defp strip_order_alias(row) when is_map(row) do
    :maps.filter(fn k, _ -> not String.starts_with?(k, "_$$$ORDER_BY_ALIAS$$$_") end, row)
  end

  defp strip_order_alias(row), do: row

  @impl true
  def begin(%Conn{} = conn, opts) do
    body = isolation_body(opts[:isolation])

    case post(conn, "/api/v1/begin/#{conn.database}", body, opts) do
      {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
        case session_id(resp) do
          nil ->
            {:error,
             %Error{reason: :server_error, http_status: status, message: "no session id returned"}}

          id ->
            {:ok, id}
        end

      other ->
        handle_status_only(other)
    end
  end

  @impl true
  def commit(%Conn{} = conn),
    do: handle_status_only(post(conn, "/api/v1/commit/#{conn.database}", nil))

  @impl true
  def rollback(%Conn{} = conn),
    do: handle_status_only(post(conn, "/api/v1/rollback/#{conn.database}", nil))

  # nil isolation → NO body (the verified default); explicit → isolationLevel body.
  defp isolation_body(nil), do: nil
  defp isolation_body(:read_committed), do: %{isolationLevel: "READ_COMMITTED"}
  defp isolation_body(:repeatable_read), do: %{isolationLevel: "REPEATABLE_READ"}

  defp isolation_body(other),
    do:
      raise(
        ArgumentError,
        "unknown isolation #{inspect(other)}; allowed: [:read_committed, :repeatable_read]"
      )

  defp session_id(%Req.Response{headers: headers}) do
    case headers["arcadedb-session-id"] do
      [id | _] -> id
      _ -> nil
    end
  end

  defp handle_status_only({:ok, %Req.Response{status: status}}) when status in 200..299, do: :ok

  defp handle_status_only({:ok, %Req.Response{status: status, body: body}}) when is_map(body),
    do: {:error, Error.from_response(status, body)}

  defp handle_status_only({:ok, %Req.Response{status: status}}),
    do: {:error, Error.from_response(status, %{"error" => "HTTP #{status}"})}

  defp handle_status_only({:error, %{reason: reason}}),
    do: {:error, %TransportError{reason: reason}}

  defp handle_status_only({:error, _}), do: {:error, %TransportError{reason: :unknown}}

  @doc false
  @spec build_body(Arcadic.Transport.request(), keyword()) :: map()
  def build_body(%{statement: statement, params: params, language: language}, opts) do
    %{language: language, command: statement}
    |> put_if(map_size(params) > 0, :params, params)
    |> put_if(opts[:limit], :limit, opts[:limit])
    |> put_if(opts[:serializer], :serializer, opts[:serializer])
    |> put_if(opts[:retries], :retries, opts[:retries])
  end

  defp put_if(map, condition, key, value),
    do: if(condition, do: Map.put(map, key, value), else: map)

  # Shared POST used by execute/begin/commit/rollback/server ops.
  @doc false
  @spec post(Conn.t(), String.t(), map() | nil, keyword()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  def post(%Conn{} = conn, path, body, opts \\ []) do
    req_opts =
      [
        url: conn.base_url <> path,
        headers: headers(conn),
        retry: false,
        finch: conn.transport_options[:finch],
        plug: conn.transport_options[:plug],
        receive_timeout: opts[:timeout] || conn.timeout
      ]
      |> maybe_put_json(body)
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    Req.post(req_opts)
  end

  # req_opts is a keyword list — use Keyword.put, NOT put_if (which does Map.put → BadMapError).
  defp maybe_put_json(opts, nil), do: opts
  defp maybe_put_json(opts, body), do: Keyword.put(opts, :json, body)

  @doc false
  @spec headers(Conn.t()) :: [{String.t(), String.t()}]
  def headers(%Conn{auth: {user, pass}, session_id: session_id}) do
    base = [{"authorization", "Basic " <> Base.encode64("#{user}:#{pass}")}]
    if session_id, do: [{"arcadedb-session-id", session_id} | base], else: base
  end

  # Result handling for a query/command response.
  defp handle_result({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299 and is_map(body) do
    Result.normalize(body)
  end

  # A 2xx whose body is empty/non-map (Req leaves an empty body as "") is a
  # no-result success — degrade to an empty row list, never a FunctionClauseError.
  defp handle_result({:ok, %Req.Response{status: status}}) when status in 200..299 do
    {:ok, []}
  end

  defp handle_result({:ok, %Req.Response{status: status, body: body}}) when is_map(body) do
    {:error, Error.from_response(status, body)}
  end

  defp handle_result({:ok, %Req.Response{status: status}}) do
    {:error, Error.from_response(status, %{"error" => "HTTP #{status}"})}
  end

  defp handle_result({:error, %{reason: reason}}), do: {:error, %TransportError{reason: reason}}

  defp handle_result({:error, exception}),
    do: {:error, %TransportError{reason: inspect_reason(exception)}}

  # Exceptions are always structs (Req returns `{:error, Exception.t()}`), so this
  # single clause is exhaustive per the type — a `_` catch-all would be dead code
  # (dialyzer `pattern_match_cov`).
  defp inspect_reason(%{__struct__: mod}), do: mod

  @impl true
  def server_command(%Conn{} = conn, command) do
    conn |> post("/api/v1/server", %{command: command}, []) |> unwrap_body()
  end

  @impl true
  def list_databases(%Conn{} = conn) do
    case get(conn, "/api/v1/databases") do
      {:ok, %{"result" => names}} when is_list(names) -> {:ok, names}
      {:ok, _} -> {:ok, []}
      {:error, error} -> {:error, error}
    end
  end

  @impl true
  def database_exists?(%Conn{} = conn, name) do
    with {:ok, names} <- list_databases(conn), do: {:ok, name in names}
  end

  @impl true
  def execute_async(%Conn{} = conn, request, opts) do
    body = request |> build_body(opts) |> Map.put(:awaitResponse, false)

    case post(conn, "/api/v1/#{endpoint(:write)}/#{conn.database}", body, opts) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status, body: b}} when is_map(b) ->
        {:error, Error.from_response(status, b)}

      {:ok, %Req.Response{status: status}} ->
        {:error, Error.from_response(status, %{"error" => "HTTP #{status}"})}

      {:error, %{reason: reason}} ->
        {:error, %TransportError{reason: reason}}

      {:error, _} ->
        {:error, %TransportError{reason: :unknown}}
    end
  end

  @impl true
  def ready?(%Conn{} = conn) do
    case raw_get(conn, "/api/v1/ready") do
      {:ok, %Req.Response{status: 204}} -> {:ok, true}
      {:ok, %Req.Response{}} -> {:ok, false}
      {:error, %{reason: reason}} -> {:error, %TransportError{reason: reason}}
      {:error, _} -> {:error, %TransportError{reason: :unknown}}
    end
  end

  # GET returning a decoded body map (for /databases).
  defp get(%Conn{} = conn, path), do: conn |> raw_get(path) |> unwrap_body()

  defp raw_get(%Conn{} = conn, path) do
    [
      url: conn.base_url <> path,
      headers: headers(conn),
      retry: false,
      finch: conn.transport_options[:finch],
      plug: conn.transport_options[:plug],
      receive_timeout: conn.timeout
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Req.get()
  end

  defp unwrap_body({:ok, %Req.Response{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  defp unwrap_body({:ok, %Req.Response{status: status, body: body}}) when is_map(body),
    do: {:error, Error.from_response(status, body)}

  defp unwrap_body({:ok, %Req.Response{status: status}}),
    do: {:error, Error.from_response(status, %{"error" => "HTTP #{status}"})}

  defp unwrap_body({:error, %{reason: reason}}), do: {:error, %TransportError{reason: reason}}
  defp unwrap_body({:error, _}), do: {:error, %TransportError{reason: :unknown}}
end
