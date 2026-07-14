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

    Requires the optional deps `{:grpc, "~> 0.11"}` and `{:protobuf, "~> 0.17"}`. The endpoint host
    and port come from `Conn.base_url`; credentials from `Conn.auth` (`{user, pass}` only — a bearer
    conn is rejected at construction, as with Bolt). Admin RPCs (Ping) authenticate by the request
    `credentials` field; data RPCs by `x-arcade-user`/`-password`/`-database` metadata.

    ## TLS

    Enabled by a secure URL scheme (`grpcs://` / `grpc+tls://` / `https://`) or
    `transport_options: [tls: true]`; plaintext otherwise. Because credentials travel on the wire,
    prefer a secure scheme in production. When TLS is on it ALWAYS verifies the server certificate
    against the OS trust store (`verify_peer` + `:public_key.cacerts_get/0`) — never `verify_none`;
    an untrusted cert fails the handshake.

    ## Redaction & value handling

    A gRPC `RPCError.message` can echo the offending statement or value. This transport maps every
    failure to an atom-only `Arcadic.Error`/`Arcadic.TransportError` reason and NEVER surfaces the
    raw wire message — the value-free contract the HTTP/Bolt transports honor. **Caveat:** the
    underlying `:grpc` library emits `[:grpc, :client, :rpc, *]` telemetry whose metadata carries the
    full request (including bound params) — a consumer that attaches a handler and logs that metadata
    would surface param values OUTSIDE arcadic's redaction boundary. DECIMAL columns decode to a
    float (lossy for large scales; an out-of-range scale decodes to `nil` rather than crashing the
    row), since arcadic takes no arbitrary-decimal dependency.
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
        return_rows: true,
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

      # Lazy end-to-end: connect, open the server cursor, then Stream.transform maps each wire
      # batch to its rows AS THE CONSUMER PULLS (no eager drain — that would defeat the cursor and
      # buffer the whole result in memory). Its after-fun disconnects the channel on normal
      # completion, early `Stream.take` halt, OR a raise mid-enumeration, so the server cursor lives
      # exactly the consume window and the channel never leaks.
      case connect(conn) do
        {:ok, ch} -> open_cursor(conn, ch, req)
        {:error, e} -> {:error, e}
      end
    end

    defp open_cursor(conn, ch, req) do
      case ArcadeDbService.Stub.stream_query(ch, req, metadata: metadata(conn)) do
        {:ok, grpc_stream} ->
          {:ok,
           Stream.transform(grpc_stream, fn -> ch end, &stream_reducer/2, &safe_disconnect/1)}

        {:error, e} ->
          safe_disconnect(ch)
          {:error, map_error(e)}
      end
    end

    defp stream_reducer({:ok, %{records: recs}}, ch), do: {Enum.map(recs, &decode_record/1), ch}
    defp stream_reducer({:error, e}, ch), do: {[{:error, map_error(e)}], ch}

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
      opts = if tls?(conn, uri), do: [cred: tls_credential()], else: []

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

    # TLS is enabled by a secure URL scheme (`grpcs://`, `grpc+tls://`, `https://`) or an explicit
    # `transport_options: [tls: true]`. Plaintext otherwise — the endpoint is credential-bearing, so
    # prefer a secure scheme in production. When on, TLS ALWAYS verifies the server certificate
    # against the OS trust store (`verify_peer` + `:public_key.cacerts_get/0`); it never falls back
    # to `verify_none`. An untrusted/self-signed server cert fails the handshake (fail-closed).
    defp tls?(%Conn{} = conn, %URI{scheme: scheme}),
      do:
        scheme in ["grpcs", "grpc+tls", "https"] or
          Keyword.get(conn.transport_options, :tls, false)

    defp tls_credential do
      GRPC.Credential.new(
        ssl: [verify: :verify_peer, cacerts: :public_key.cacerts_get(), depth: 3]
      )
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
    defp to_grpc_value(nil), do: %GrpcValue{}

    # Temporal structs bind as ISO-8601 strings (what the HTTP transport's Jason encoding also
    # sends) — a struct would otherwise fall into the `is_map` clause below and serialize its
    # `__struct__`/fields as a nonsense map. Handle them BEFORE the generic map clause.
    defp to_grpc_value(%Date{} = d), do: %GrpcValue{kind: {:string_value, Date.to_iso8601(d)}}

    defp to_grpc_value(%DateTime{} = d),
      do: %GrpcValue{kind: {:string_value, DateTime.to_iso8601(d)}}

    defp to_grpc_value(%NaiveDateTime{} = d),
      do: %GrpcValue{kind: {:string_value, NaiveDateTime.to_iso8601(d)}}

    defp to_grpc_value(v) when is_list(v),
      do: %GrpcValue{kind: {:list_value, %GrpcList{values: Enum.map(v, &to_grpc_value/1)}}}

    # Plain (non-struct) maps only — a struct param not handled above is a caller error, and
    # raising loudly beats silently shipping a `__struct__`-bearing map to the server.
    defp to_grpc_value(v) when is_map(v) and not is_struct(v) do
      %GrpcValue{
        kind:
          {:map_value,
           %GrpcMap{entries: Map.new(v, fn {k, val} -> {to_string(k), to_grpc_value(val)} end)}}
      }
    end

    defp decode_record(%{properties: props} = rec) do
      props
      |> Map.new(fn {k, gv} -> {k, from_grpc_value(gv)} end)
      |> put_identity("@rid", rec.rid)
      |> put_identity("@type", rec.type)
    end

    defp put_identity(map, _key, v) when v in [nil, ""], do: map
    defp put_identity(map, key, v), do: Map.put(map, key, v)

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

    # A DATETIME column arrives as a google.protobuf.Timestamp (seconds + nanos) → decode to a
    # DateTime rather than dropping it to nil (the silent-data-loss class).
    defp from_kind({:timestamp_value, %{seconds: s, nanos: n}}),
      do: DateTime.from_unix!(s * 1_000_000_000 + n, :nanosecond)

    # An exact DECIMAL arrives as unscaled + scale. Elixir has no built-in arbitrary decimal and
    # arcadic takes no Decimal dep, so surface it as a float (unscaled × 10^-scale) — lossy for
    # large scales, but a real number beats a silent nil. Scale is bounded to a sane range so a
    # pathological/hostile value cannot raise `ArithmeticError` and crash the whole row decode
    # (ArcadeDB DECIMAL scale is ≤ 38); out-of-range → nil rather than a crash.
    defp from_kind({:decimal_value, %{unscaled: u, scale: sc}}) when sc in 0..38,
      do: u / :math.pow(10, sc)

    defp from_kind({:decimal_value, _}), do: nil

    # An embedded document → a nested plain map (same shape a map_value decodes to).
    defp from_kind({:embedded_value, %{fields: f}}),
      do: Map.new(f, fn {k, gv} -> {k, from_grpc_value(gv)} end)

    defp from_kind(nil), do: nil
    # Any genuinely unknown/unset kind → nil (an absent oneof, not a droppable value).
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
