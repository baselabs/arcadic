# Compile-guarded: this transport references the generated gRPC stubs and `GRPC.Stub`,
# which only exist when the optional :grpc + :protobuf deps are present. HTTP/Bolt-only
# consumers (who don't add those deps) skip this module cleanly — same pattern as the
# generated proto file it drives.
if Code.ensure_loaded?(Protobuf) and Code.ensure_loaded?(GRPC.Service) do
  defmodule Arcadic.Transport.Grpc do
    @moduledoc """
    Optional gRPC transport over ArcadeDB's gRPC plugin (`GrpcServerPlugin`).

    Its reason to exist is `query_stream/3`: ArcadeDB's `StreamQuery` in `CURSOR` mode is a
    **real server cursor** — the server runs the query once and streams `batch_size`-sized
    batches as the client iterates (O(n), server-paced), where the HTTP transport can only
    offset-page (O(n²) in the general case) and Bolt streams Cypher only. `execute/4` covers
    the unary read/write path; everything admin/transactional is `:not_supported` (use an HTTP
    `Conn` for those, exactly as the Bolt transport does).

    ## Selecting it

        conn =
          Arcadic.connect("grpc://localhost:50051", "mydb",
            transport: Arcadic.Transport.Grpc,
            auth: {"root", System.fetch_env!("PW")}
          )

    Requires the optional deps `{:grpc, "~> 0.11"}` and `{:protobuf, "~> 0.17"}`. The endpoint
    is taken from the `Conn.base_url` host/port (any scheme; `grpc://` reads best); credentials
    from `Conn.auth` (`{user, pass}`). TLS: pass `transport_options: [tls: true]` (verify_peer via
    `:castore`); plaintext otherwise.

    ## Redaction

    A gRPC `RPCError.message` can echo the offending statement or value. This transport maps every
    failure to an atom-only `Arcadic.Error`/`Arcadic.TransportError` reason and NEVER surfaces the
    raw wire message — the value-free contract the HTTP/Bolt transports honor.
    """
    @behaviour Arcadic.Transport

    alias Arcadic.{Conn, Error, TransportError}

    alias Com.Arcadedb.Grpc.{
      ArcadeDbAdminService,
      ArcadeDbService,
      DatabaseCredentials,
      ExecuteCommandRequest,
      ExecuteQueryRequest,
      GrpcList,
      GrpcMap,
      GrpcValue,
      PingRequest,
      StreamQueryRequest
    }

    @impl true
    def execute(%Conn{} = conn, :read, %{statement: stmt, params: params, language: lang}, _opts) do
      req = %ExecuteQueryRequest{
        database: conn.database,
        query: stmt,
        parameters: encode_params(params),
        language: normalize_language(lang),
        credentials: credentials(conn)
      }

      with_channel(conn, fn ch ->
        case ArcadeDbService.Stub.execute_query(ch, req, metadata: metadata(conn)) do
          {:ok, resp} ->
            {:ok, resp.results |> Enum.flat_map(& &1.records) |> Enum.map(&decode_record/1)}

          {:error, e} ->
            {:error, map_error(e)}
        end
      end)
    end

    def execute(%Conn{} = conn, :write, %{statement: stmt, params: params, language: lang}, _opts) do
      req = %ExecuteCommandRequest{
        database: conn.database,
        command: stmt,
        parameters: encode_params(params),
        language: normalize_language(lang),
        credentials: credentials(conn)
      }

      with_channel(conn, fn ch ->
        case ArcadeDbService.Stub.execute_command(ch, req, metadata: metadata(conn)) do
          {:ok, %{success: true} = resp} -> {:ok, Enum.map(resp.records, &decode_record/1)}
          {:ok, %{success: false}} -> {:error, %Error{reason: :command_failed}}
          {:error, e} -> {:error, map_error(e)}
        end
      end)
    end

    @impl true
    def query_stream(%Conn{} = conn, %{statement: stmt, params: params, language: lang}, opts) do
      batch = Keyword.get(opts, :chunk_size, 100)

      req = %StreamQueryRequest{
        database: conn.database,
        query: stmt,
        parameters: encode_params(params),
        language: normalize_language(lang),
        batch_size: batch,
        retrieval_mode: :CURSOR,
        credentials: credentials(conn)
      }

      # Stream.resource keeps the channel open across enumeration and closes it (disconnect)
      # when the consumer finishes or the process crashes — the server cursor lives for exactly
      # that window. Each element yielded upstream is a QueryResult batch; we flat-map its records.
      stream =
        Stream.resource(
          fn -> start_stream(conn, req) end,
          &next_batch/1,
          &close_stream/1
        )

      {:ok, stream}
    end

    @impl true
    def ready?(%Conn{} = conn), do: ping(conn)

    @impl true
    def health?(%Conn{} = conn), do: ping(conn)

    # --- Admin / transactional surface: not this transport's job (use an HTTP Conn) ---
    @impl true
    def begin(%Conn{}, _opts), do: {:error, %Error{reason: :not_supported}}
    @impl true
    def commit(%Conn{}), do: {:error, %Error{reason: :not_supported}}
    @impl true
    def rollback(%Conn{}), do: {:error, %Error{reason: :not_supported}}
    @impl true
    def server_command(%Conn{}, _command), do: {:error, %Error{reason: :not_supported}}
    @impl true
    def server_get(%Conn{}, _path), do: {:error, %Error{reason: :not_supported}}
    @impl true
    def login(%Conn{}), do: {:error, %Error{reason: :not_supported}}
    @impl true
    def logout(%Conn{}), do: {:error, %Error{reason: :not_supported}}
    @impl true
    def list_databases(%Conn{}), do: {:error, %Error{reason: :not_supported}}
    @impl true
    def database_exists?(%Conn{}, _name), do: {:error, %Error{reason: :not_supported}}

    # --- internals ---

    defp ping(conn) do
      # Ping is on the ADMIN service, which authenticates by the body `credentials` field
      # (the data service uses `x-arcade-*` metadata — verified live). So Ping carries creds.
      with_channel(conn, fn ch ->
        case ArcadeDbAdminService.Stub.ping(ch, %PingRequest{credentials: credentials(conn)}) do
          {:ok, %{ok: ok}} -> {:ok, ok}
          {:error, e} -> {:error, map_error(e)}
        end
      end)
    end

    defp start_stream(conn, req) do
      case connect(conn) do
        {:ok, ch} ->
          case ArcadeDbService.Stub.stream_query(ch, req, metadata: metadata(conn)) do
            {:ok, grpc_stream} -> {:cont, ch, grpc_stream}
            {:error, e} -> {:halt_err, ch, map_error(e)}
          end

        {:error, e} ->
          {:halt_err, nil, e}
      end
    end

    defp next_batch({:halt_err, ch, err}), do: {[{:error, err}], {:done, ch}}
    defp next_batch({:done, _ch} = acc), do: {:halt, acc}

    defp next_batch({:cont, ch, grpc_stream}) do
      # Pull the whole gRPC stream once (it is itself lazy on the wire); flat-map records.
      # A per-batch error is surfaced as a single {:error, _} element, never a raised value.
      rows =
        Enum.flat_map(grpc_stream, fn
          {:ok, %{records: recs}} -> Enum.map(recs, &decode_record/1)
          {:error, e} -> [{:error, map_error(e)}]
        end)

      {rows, {:done, ch}}
    end

    defp close_stream({_tag, nil}), do: :ok
    defp close_stream({_tag, ch}), do: safe_disconnect(ch)
    defp close_stream(_), do: :ok

    defp with_channel(conn, fun) do
      case connect(conn) do
        {:ok, ch} ->
          try do
            fun.(ch)
          after
            safe_disconnect(ch)
          end

        {:error, e} ->
          {:error, e}
      end
    end

    defp connect(%Conn{} = conn), do: connect(conn, 1)

    # Retry the channel open ONCE on a transient failure. Opening a fresh gun HTTP/2 connection
    # per call can race the first-connect on a cold client supervisor; the retry (no RPC has run,
    # so nothing has a side effect yet) makes the transport stable under connect churn without a
    # persistent pool. A pooled/reused channel is the perf+robustness follow-up (see moduledoc).
    defp connect(%Conn{} = conn, retries) do
      ensure_client_supervisor()
      uri = URI.parse(conn.base_url)
      endpoint = "#{uri.host || "localhost"}:#{uri.port || 50051}"

      opts =
        if Keyword.get(conn.transport_options, :tls, false),
          do: [cred: GRPC.Credential.new(ssl: [])],
          else: []

      case GRPC.Stub.connect(endpoint, opts) do
        {:ok, ch} ->
          {:ok, ch}

        {:error, _reason} when retries > 0 ->
          Process.sleep(25)
          connect(conn, retries - 1)

        {:error, _reason} ->
          {:error, %TransportError{reason: :connect_failed}}
      end
    end

    # grpc 0.11 routes client connections through a global `GRPC.Client.Supervisor` that its
    # application does NOT auto-start. Start it lazily and idempotently so the transport works
    # without the consumer wiring it into their own tree. CRUCIAL: `start_link` LINKS it to the
    # calling process, so we `unlink` — otherwise the caller (e.g. a short-lived ExUnit test
    # process, or any transient caller) dying takes the global supervisor with it, breaking the
    # next call. Unlinked, it persists as the client infrastructure it is meant to be. A consumer
    # that prefers explicit ownership MAY add `{GRPC.Client.Supervisor, []}` to their own tree —
    # a running instance short-circuits this. Any start race resolves to `:already_started`.
    defp ensure_client_supervisor do
      if Process.whereis(GRPC.Client.Supervisor) == nil do
        case GRPC.Client.Supervisor.start_link([]) do
          {:ok, pid} -> Process.unlink(pid)
          {:error, {:already_started, _}} -> :ok
          _ -> :ok
        end
      end

      :ok
    end

    defp safe_disconnect(ch) do
      _ = GRPC.Stub.disconnect(ch)
      :ok
    end

    defp metadata(%Conn{} = conn) do
      {user, pass} = user_pass(conn)

      %{
        "x-arcade-user" => user,
        "x-arcade-password" => pass,
        "x-arcade-database" => conn.database
      }
    end

    defp credentials(%Conn{} = conn) do
      {user, pass} = user_pass(conn)
      %DatabaseCredentials{username: user, password: pass}
    end

    defp user_pass(%Conn{auth: {user, pass}}) when is_binary(user) and is_binary(pass),
      do: {user, pass}

    defp user_pass(%Conn{transport_options: opts}) do
      {to_string(Keyword.get(opts, :username, "")), to_string(Keyword.get(opts, :password, ""))}
    end

    defp normalize_language(nil), do: "sql"
    defp normalize_language(lang) when is_atom(lang), do: Atom.to_string(lang)
    defp normalize_language(lang) when is_binary(lang), do: lang

    # --- value codec (Elixir <-> GrpcValue) ---

    defp encode_params(params) when is_map(params) do
      Map.new(params, fn {k, v} -> {to_string(k), to_grpc_value(v)} end)
    end

    defp encode_params(_), do: %{}

    defp to_grpc_value(v) when is_boolean(v), do: %GrpcValue{kind: {:bool_value, v}}
    defp to_grpc_value(v) when is_integer(v), do: %GrpcValue{kind: {:int64_value, v}}
    defp to_grpc_value(v) when is_float(v), do: %GrpcValue{kind: {:double_value, v}}
    defp to_grpc_value(v) when is_binary(v), do: %GrpcValue{kind: {:string_value, v}}

    defp to_grpc_value(v) when is_list(v),
      do: %GrpcValue{kind: {:list_value, %GrpcList{values: Enum.map(v, &to_grpc_value/1)}}}

    defp to_grpc_value(v) when is_map(v) do
      %GrpcValue{
        kind:
          {:map_value,
           %GrpcMap{entries: Map.new(v, fn {k, val} -> {to_string(k), to_grpc_value(val)} end)}}
      }
    end

    defp to_grpc_value(nil), do: %GrpcValue{}

    defp decode_record(%{properties: props} = rec) do
      base = Map.new(props, fn {k, gv} -> {k, from_grpc_value(gv)} end)
      base = if rec.rid not in [nil, ""], do: Map.put(base, "@rid", rec.rid), else: base
      if rec.type not in [nil, ""], do: Map.put(base, "@type", rec.type), else: base
    end

    defp from_grpc_value(%GrpcValue{kind: kind}), do: from_kind(kind)
    defp from_grpc_value(_), do: nil

    defp from_kind({:bool_value, v}), do: v
    defp from_kind({:int32_value, v}), do: v
    defp from_kind({:int64_value, v}), do: v
    defp from_kind({:float_value, v}), do: v
    defp from_kind({:double_value, v}), do: v
    defp from_kind({:string_value, v}), do: v
    defp from_kind({:bytes_value, v}), do: v
    defp from_kind({:list_value, %GrpcList{values: vs}}), do: Enum.map(vs, &from_grpc_value/1)

    defp from_kind({:map_value, %GrpcMap{entries: es}}),
      do: Map.new(es, fn {k, gv} -> {k, from_grpc_value(gv)} end)

    defp from_kind({:link_value, link}), do: link.rid
    defp from_kind(nil), do: nil
    # Embedded/timestamp/decimal: fall through to nil rather than leak a raw struct into a row.
    defp from_kind(_), do: nil

    # --- error mapping (value-free: an atom reason, never the wire message) ---

    defp map_error(%GRPC.RPCError{status: status}), do: error_for_status(status)
    defp map_error(_), do: %TransportError{reason: :grpc_error}

    defp error_for_status(16), do: %Error{reason: :unauthorized}
    defp error_for_status(3), do: %Error{reason: :invalid_statement}
    defp error_for_status(5), do: %Error{reason: :not_found}
    defp error_for_status(7), do: %Error{reason: :forbidden}
    defp error_for_status(13), do: %Error{reason: :server_error}
    defp error_for_status(14), do: %TransportError{reason: :unavailable}
    defp error_for_status(4), do: %TransportError{reason: :timeout}
    defp error_for_status(_), do: %TransportError{reason: :grpc_error}
  end
end
