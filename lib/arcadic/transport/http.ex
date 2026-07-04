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
  defp handle_result({:ok, %Req.Response{status: status, body: body}}) when status in 200..299 do
    Result.normalize(body)
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
end
