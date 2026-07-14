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
    the unary read/write path, and `begin`/`commit`/`rollback` run gRPC session transactions
    (tx-scoped reads/writes carry the `transaction_id`). The remaining HTTP-shaped admin/server
    surface (server settings, users, login/logout) stays `:not_supported` — use an HTTP `Conn`.

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

    ## Connection pooling

    By default each call opens a fresh channel. For channel reuse, add the caller-supervised
    `{Arcadic.Transport.Grpc.ChannelPool, []}` to your supervision tree — the transport then reuses one
    long-lived, HTTP/2-multiplexed channel per `{host, port, tls?}` endpoint across all calls (a gRPC
    channel multiplexes concurrent streams). Absent the pool, the per-call connect is used (no behavior
    change). Tenant-blind — the pool keys on the endpoint only.

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
    full request (bound params, AND for `batch_ingest`/ingest the whole record batch) — a consumer
    that attaches a handler and logs that metadata would surface those values OUTSIDE arcadic's
    redaction boundary. Values are encoded value-free: any value with no gRPC representation (an
    integer outside int64, a non-UTF-8 binary) yields `{:error, :invalid_params | :invalid_record}`,
    never a `Protobuf.EncodeError` that echoes it — so gRPC rejects a few large-integer values HTTP
    accepts as JSON text (a documented, mechanically-forced divergence). DECIMAL columns decode to a
    float (lossy for large scales; an out-of-range scale decodes to `nil` rather than crashing the
    row), since arcadic takes no arbitrary-decimal dependency.

    `batch_ingest` (graph vertex/edge bulk) maps to the gRPC `GraphBatchLoad` stream — the twin of
    HTTP `POST /api/v1/batch`. Because `GraphBatchChunk` carries no transaction field, a batch CANNOT
    join an open `transaction/3`; called on a session-bearing conn it **fails closed**
    (`:transaction_unsupported`) rather than silently auto-commit outside the caller's tx (on HTTP the
    same batch rides the session). Use the document-ingest arm or an `UNWIND $rows` statement in a tx.
    """
    @behaviour Arcadic.Transport

    alias Arcadic.{Conn, Error, TransportError}
    alias Arcadic.Transport.Grpc.ChannelPool

    alias Com.Arcadedb.Grpc.{
      ArcadeDbAdminService,
      ArcadeDbService,
      BeginTransactionRequest,
      BulkInsertRequest,
      CommitTransactionRequest,
      CreateDatabaseRequest,
      CreateRecordRequest,
      DatabaseCredentials,
      DeleteRecordRequest,
      DropDatabaseRequest,
      ExecuteCommandRequest,
      ExecuteQueryRequest,
      ExistsDatabaseRequest,
      GetServerInfoRequest,
      GraphBatchChunk,
      GraphBatchOptions,
      GraphBatchRecord,
      GraphBatchResult,
      GrpcList,
      GrpcMap,
      GrpcRecord,
      GrpcValue,
      InsertChunk,
      InsertOptions,
      InsertSummary,
      ListDatabasesRequest,
      LookupByRidRequest,
      PingRequest,
      PropertiesUpdate,
      RollbackTransactionRequest,
      StreamQueryRequest,
      TransactionContext,
      UpdateRecordRequest
    }

    @impl true
    def execute(%Conn{} = conn, :read, %{statement: stmt, params: params, language: lang}, _opts) do
      with {:ok, encoded} <- safe_encode_params(params),
           do: run_query(conn, stmt, encoded, lang)
    end

    def execute(%Conn{} = conn, :write, %{statement: stmt, params: params, language: lang}, _opts) do
      with {:ok, encoded} <- safe_encode_params(params),
           do: run_command(conn, stmt, encoded, lang)
    end

    defp run_query(conn, stmt, encoded, lang) do
      req = %ExecuteQueryRequest{
        database: conn.database,
        query: stmt,
        parameters: encoded,
        language: normalize_language(lang),
        credentials: credentials(conn),
        transaction: transaction_context(conn)
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

    defp run_command(conn, stmt, encoded, lang) do
      req = %ExecuteCommandRequest{
        database: conn.database,
        command: stmt,
        parameters: encoded,
        language: normalize_language(lang),
        return_rows: true,
        credentials: credentials(conn),
        transaction: transaction_context(conn)
      }

      with_channel(conn, fn ch ->
        case ArcadeDbService.Stub.execute_command(ch, req, metadata: metadata(conn)) do
          {:ok, %{success: true} = resp} -> {:ok, Enum.map(resp.records, &decode_record/1)}
          {:ok, %{success: false}} -> {:error, %Error{reason: :command_failed}}
          {:error, e} -> {:error, map_error(e)}
        end
      end)
    end

    # EXPLAIN/PROFILE: the facade prepends the prefix; the plan comes back as a row carrying
    # `executionPlanAsString` (human string) + `executionPlan` (the raw plan map).
    @impl true
    def explain(%Conn{} = conn, %{statement: stmt, params: params, language: lang}, _opts) do
      with {:ok, encoded} <- safe_encode_params(params),
           do: run_explain(conn, stmt, encoded, lang)
    end

    defp run_explain(conn, stmt, encoded, lang) do
      req = %ExecuteQueryRequest{
        database: conn.database,
        query: stmt,
        parameters: encoded,
        language: normalize_language(lang),
        credentials: credentials(conn),
        transaction: transaction_context(conn)
      }

      with_channel(conn, fn ch ->
        case ArcadeDbService.Stub.execute_query(ch, req, metadata: metadata(conn)) do
          {:ok, resp} -> {:ok, plan_from_rows(resp)}
          {:error, e} -> {:error, map_error(e)}
        end
      end)
    end

    defp plan_from_rows(resp) do
      row =
        resp.results |> Enum.flat_map(& &1.records) |> Enum.map(&decode_record/1) |> List.first()

      row = row || %{}

      %{
        plan: Map.get(row, "executionPlanAsString", ""),
        plan_tree: Map.get(row, "executionPlan", %{}),
        rows: []
      }
    end

    @impl true
    def query_stream(%Conn{} = conn, %{statement: stmt, params: params, language: lang}, opts) do
      batch = Keyword.get(opts, :chunk_size, 100)

      with {:ok, encoded} <- safe_encode_params(params) do
        req = %StreamQueryRequest{
          database: conn.database,
          query: stmt,
          parameters: encoded,
          language: normalize_language(lang),
          batch_size: batch,
          retrieval_mode: :CURSOR,
          credentials: credentials(conn),
          transaction: transaction_context(conn)
        }

        # Lazy end-to-end: connect, open the server cursor, then Stream.transform maps each wire
        # batch to its rows AS THE CONSUMER PULLS (no eager drain — that would defeat the cursor and
        # buffer the whole result in memory). Its after-fun disconnects the channel on normal
        # completion, early `Stream.take` halt, OR a raise mid-enumeration, so the server cursor lives
        # exactly the consume window and the channel never leaks.
        case connect(conn) do
          {:ok, ch, mode} -> open_cursor(conn, ch, req, mode)
          {:error, e} -> {:error, e}
        end
      end
    end

    defp open_cursor(conn, ch, req, mode) do
      case ArcadeDbService.Stub.stream_query(ch, req, metadata: metadata(conn)) do
        {:ok, grpc_stream} ->
          {:ok,
           Stream.transform(grpc_stream, fn -> ch end, &stream_reducer/2, &release(&1, mode))}

        {:error, e} ->
          release(ch, mode)
          {:error, map_error(e)}
      end
    end

    defp stream_reducer({:ok, %{records: recs}}, ch), do: {Enum.map(recs, &decode_record/1), ch}
    defp stream_reducer({:error, e}, ch), do: {[{:error, map_error(e)}], ch}

    # --- Bulk graph ingest → GraphBatchLoad (client-streaming; the twin of HTTP POST /api/v1/batch) ---
    @impl true
    # GraphBatchChunk carries NO `transaction` field — a batch cannot join an open tx. Fail CLOSED
    # when the conn holds a session, rather than silently auto-commit the batch OUTSIDE the caller's
    # transaction (a silent-atomicity divergence from HTTP, which rides the session header). A caller
    # in a tx uses an `UNWIND $rows` / `INSERT` statement (document ingest also fails closed in a tx).
    def batch_ingest(%Conn{session_id: sid}, _ndjson, _opts) when is_binary(sid),
      do: {:error, %Error{reason: :transaction_unsupported}}

    def batch_ingest(%Conn{} = conn, ndjson, opts) do
      # Build + VALIDATE all records value-free BEFORE opening the channel: an unencodable value
      # (int > int64, non-UTF-8) → {:error, :invalid_record} with NO value echoed, and no mid-send
      # raise. The re-parse is safe — Bulk only hands us NDJSON it just encoded (bulk.ex).
      with {:ok, records} <- ndjson_to_graph_records(ndjson),
           do: run_graph_batch(conn, records, opts)
    end

    defp run_graph_batch(conn, records, opts) do
      chunk = %GraphBatchChunk{
        database: conn.database,
        credentials: credentials(conn),
        options: graph_batch_options(opts),
        records: records
      }

      with_channel(conn, fn ch ->
        stream = ArcadeDbService.Stub.graph_batch_load(ch, metadata: metadata(conn))
        GRPC.Stub.send_request(stream, chunk, end_stream: true)

        case GRPC.Stub.recv(stream) do
          {:ok, %GraphBatchResult{} = r} -> {:ok, graph_result_to_http_shape(r)}
          {:ok, _other} -> {:error, %Error{reason: :server_error}}
          {:error, e} -> {:error, map_error(e)}
        end
      end)
    end

    defp ndjson_to_graph_records(ndjson) do
      ndjson
      |> IO.iodata_to_binary()
      |> String.split("\n", trim: true)
      |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
        with {:ok, map} <- Jason.decode(line),
             {:ok, rec} <- map_to_graph_record(map) do
          {:cont, {:ok, [rec | acc]}}
        else
          _ -> {:halt, {:error, %Error{reason: :invalid_record}}}
        end
      end)
      |> case do
        {:ok, recs} -> {:ok, Enum.reverse(recs)}
        {:error, _} = err -> err
      end
    end

    # Map a caller vertex/edge map → GraphBatchRecord: structural keys become typed fields, the rest
    # become value-free-encoded properties (safe_map_entries → :error on an unencodable value).
    defp map_to_graph_record(map) when is_map(map) do
      {structural, props} = Map.split(map, ["@type", "@class", "@id", "@from", "@to"])

      case safe_map_entries(props) do
        {:ok, prop_entries} ->
          {:ok,
           %GraphBatchRecord{
             kind: if(Map.get(structural, "@type") == "edge", do: :EDGE, else: :VERTEX),
             type_name: Map.get(structural, "@class"),
             temp_id: Map.get(structural, "@id"),
             from_ref: Map.get(structural, "@from"),
             to_ref: Map.get(structural, "@to"),
             properties: prop_entries
           }}

        :error ->
          :error
      end
    end

    defp map_to_graph_record(_), do: :error

    defp graph_batch_options(opts) do
      light = Keyword.get(opts, :light_edges)
      commit = Keyword.get(opts, :commit_every)

      if is_nil(light) and is_nil(commit),
        do: nil,
        else: %GraphBatchOptions{light_edges: light || false, commit_every: commit || 0}
    end

    # Re-key the atom-keyed GraphBatchResult → the string-keyed map `Arcadic.Bulk.shape/1` requires
    # (`is_map_key(body, "verticesCreated")`), so Bulk.ingest is transport-transparent across HTTP/gRPC.
    defp graph_result_to_http_shape(%GraphBatchResult{} = r) do
      %{
        "verticesCreated" => r.vertices_created,
        "edgesCreated" => r.edges_created,
        "elapsedMs" => r.elapsed_ms,
        "idMapping" => r.id_mapping || %{}
      }
    end

    # --- Document ingest → BulkInsert (unary; rows into a target class, InsertSummary counts) ---
    @impl true
    # BulkInsert manages its OWN transaction (PER_REQUEST) and does NOT honor an outer session tx —
    # live-proven: a BulkInsert inside `transaction/3` survives the rollback (transaction_mode NONE +
    # a passed TransactionContext did not change this). So, like batch_ingest, FAIL CLOSED inside a tx
    # rather than silently auto-commit outside the caller's transaction (tx symmetry, review #2).
    def insert_rows(%Conn{session_id: sid}, _target_class, _rows, _opts) when is_binary(sid),
      do: {:error, %Error{reason: :transaction_unsupported}}

    def insert_rows(%Conn{} = conn, target_class, rows, opts) do
      # Encode + validate rows value-free BEFORE the wire (same shared encoder as batch_ingest).
      # A `:chunk_size` opt streams the rows via InsertStream (client-streaming, chunked send) instead
      # of the unary BulkInsert — the two share the same InsertSummary result shape.
      with {:ok, grpc_rows} <- encode_rows(rows) do
        cond do
          # Empty rows never hit the wire (defense-in-depth: the facade already short-circuits, but a
          # direct callback caller must not stall — an empty InsertStream sends no chunk + never
          # half-closes, so `recv` would block forever).
          grpc_rows == [] ->
            {:ok, %{received: 0, inserted: 0, updated: 0, ignored: 0, failed: 0, errors: []}}

          Keyword.get(opts, :chunk_size) ->
            run_insert_stream(
              conn,
              target_class,
              grpc_rows,
              Keyword.fetch!(opts, :chunk_size),
              opts
            )

          true ->
            run_bulk_insert(conn, target_class, grpc_rows, opts)
        end
      end
    end

    defp run_bulk_insert(conn, target_class, grpc_rows, opts) do
      req = %BulkInsertRequest{
        database: conn.database,
        credentials: credentials(conn),
        options: insert_options(conn, target_class, opts),
        rows: grpc_rows
      }

      with_channel(conn, fn ch ->
        case ArcadeDbService.Stub.bulk_insert(ch, req, metadata: metadata(conn)) do
          {:ok, %InsertSummary{} = s} -> {:ok, insert_summary_to_map(s)}
          {:error, e} -> {:error, map_error(e)}
        end
      end)
    end

    # InsertStream (client-streaming): send the rows as `size`-sized InsertChunks, `last: true` on the
    # final chunk, then one InsertSummary reply. `options.database` is required (same as BulkInsert).
    defp run_insert_stream(conn, target_class, grpc_rows, size, opts) do
      opts_msg = insert_options(conn, target_class, opts)
      chunks = Enum.chunk_every(grpc_rows, max(size, 1))
      last_index = length(chunks) - 1

      with_channel(conn, fn ch ->
        stream = ArcadeDbService.Stub.insert_stream(ch, metadata: metadata(conn))

        chunks
        |> Enum.with_index()
        |> Enum.each(fn {chunk_rows, i} ->
          last? = i == last_index

          msg = %InsertChunk{
            database: conn.database,
            credentials: credentials(conn),
            options: opts_msg,
            rows: chunk_rows,
            last: last?
          }

          GRPC.Stub.send_request(stream, msg, end_stream: last?)
        end)

        case GRPC.Stub.recv(stream) do
          {:ok, %InsertSummary{} = s} -> {:ok, insert_summary_to_map(s)}
          {:error, e} -> {:error, map_error(e)}
        end
      end)
    end

    defp encode_rows(rows) do
      rows
      |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
        case row_to_grpc_record(row) do
          {:ok, rec} -> {:cont, {:ok, [rec | acc]}}
          :error -> {:halt, {:error, %Error{reason: :invalid_record}}}
        end
      end)
      |> case do
        {:ok, recs} -> {:ok, Enum.reverse(recs)}
        {:error, _} = err -> err
      end
    end

    defp row_to_grpc_record(row) when is_map(row) do
      case safe_map_entries(row) do
        {:ok, entries} -> {:ok, %GrpcRecord{properties: entries}}
        :error -> :error
      end
    end

    defp row_to_grpc_record(_), do: :error

    # `database` is required in the options (the BulkInsert path reads it there, not only top-level —
    # an unset options.database → "Invalid database name: name is required", live-probed).
    defp insert_options(%Conn{} = conn, target_class, opts) do
      %InsertOptions{
        database: conn.database,
        target_class: target_class,
        key_columns: Keyword.get(opts, :key_columns, []),
        conflict_mode: conflict_mode(Keyword.get(opts, :conflict_mode))
      }
    end

    defp conflict_mode(nil), do: :CONFLICT_ERROR
    defp conflict_mode(:error), do: :CONFLICT_ERROR
    defp conflict_mode(:update), do: :CONFLICT_UPDATE
    defp conflict_mode(:ignore), do: :CONFLICT_IGNORE
    defp conflict_mode(:abort), do: :CONFLICT_ABORT

    defp conflict_mode(_),
      do:
        raise(ArgumentError, "unknown conflict_mode; allowed: [:error, :update, :ignore, :abort]")

    # Value-free: the per-row error carries only `row_index` + a categorical `code` — NEVER the
    # InsertError `message`/`field`, which echo the offending value (Rule 3). `code` is proto-typed a
    # free-form `:string`, so it is NOT trusted verbatim: `safe_code/1` passes it through ONLY if it
    # matches a categorical-token shape (upper-snake, bounded), else `nil` — so a value-bearing `code`
    # for some rejection type cannot leak, regardless of server behavior.
    defp insert_summary_to_map(%InsertSummary{} = s) do
      %{
        received: s.received,
        inserted: s.inserted,
        updated: s.updated,
        ignored: s.ignored,
        failed: s.failed,
        errors: Enum.map(s.errors, fn e -> %{row_index: e.row_index, code: safe_code(e.code)} end)
      }
    end

    defp safe_code(code) when is_binary(code) do
      if Regex.match?(~r/\A[A-Z][A-Z0-9_]{0,63}\z/, code), do: code, else: nil
    end

    defp safe_code(_), do: nil

    # --- Single-record CRUD (CreateRecord/LookupByRid/UpdateRecord/DeleteRecord; raw maps) ---
    @impl true
    def create_record(%Conn{} = conn, type, props, _opts) do
      with {:ok, entries} <- safe_props(props),
           do: run_create_record(conn, type, entries)
    end

    defp run_create_record(conn, type, entries) do
      req = %CreateRecordRequest{
        database: conn.database,
        credentials: credentials(conn),
        type: type,
        record: %GrpcRecord{properties: entries},
        transaction: transaction_context(conn)
      }

      with_channel(conn, fn ch ->
        case ArcadeDbService.Stub.create_record(ch, req, metadata: metadata(conn)) do
          {:ok, %{rid: rid}} when is_binary(rid) and rid != "" -> {:ok, rid}
          {:ok, _} -> {:error, %Error{reason: :server_error}}
          {:error, e} -> {:error, map_error(e)}
        end
      end)
    end

    @impl true
    def lookup_record(%Conn{} = conn, rid, _opts) do
      req = %LookupByRidRequest{
        database: conn.database,
        credentials: credentials(conn),
        rid: rid,
        transaction: transaction_context(conn)
      }

      with_channel(conn, fn ch ->
        ch
        |> ArcadeDbService.Stub.lookup_by_rid(req, metadata: metadata(conn))
        |> lookup_result()
      end)
    end

    # An absent record surfaces EITHER as `found: false` OR a NOT_FOUND gRPC status (deleted rid) —
    # both are "absent" (`{:ok, nil}`), so lookup is idempotent; any other error propagates value-free.
    defp lookup_result({:ok, %{found: true, record: rec}}), do: {:ok, decode_record(rec)}
    defp lookup_result({:ok, %{found: false}}), do: {:ok, nil}

    defp lookup_result({:error, e}) do
      case map_error(e) do
        %Error{reason: :not_found} -> {:ok, nil}
        err -> {:error, err}
      end
    end

    @impl true
    def update_record(%Conn{} = conn, rid, props, opts) do
      with {:ok, entries} <- safe_props(props),
           do: run_update_record(conn, rid, entries, opts)
    end

    defp run_update_record(conn, rid, entries, opts) do
      # oneof `payload` is a tagged tuple (like GrpcValue.kind): `replace: true` replaces the whole
      # record; the default merges properties (partial update via PropertiesUpdate).
      payload =
        if Keyword.get(opts, :replace, false),
          do: {:record, %GrpcRecord{properties: entries}},
          else: {:partial, %PropertiesUpdate{properties: entries}}

      req = %UpdateRecordRequest{
        database: conn.database,
        credentials: credentials(conn),
        rid: rid,
        payload: payload,
        transaction: transaction_context(conn)
      }

      with_channel(conn, fn ch ->
        case ArcadeDbService.Stub.update_record(ch, req, metadata: metadata(conn)) do
          {:ok, %{success: true}} -> :ok
          {:ok, _} -> {:error, %Error{reason: :server_error}}
          {:error, e} -> {:error, map_error(e)}
        end
      end)
    end

    @impl true
    def delete_record(%Conn{} = conn, rid, _opts) do
      req = %DeleteRecordRequest{
        database: conn.database,
        rid: rid,
        credentials: credentials(conn),
        transaction: transaction_context(conn)
      }

      with_channel(conn, fn ch ->
        case ArcadeDbService.Stub.delete_record(ch, req, metadata: metadata(conn)) do
          {:ok, %{success: true}} -> :ok
          {:ok, _} -> {:error, %Error{reason: :server_error}}
          {:error, e} -> {:error, map_error(e)}
        end
      end)
    end

    # Value-free: an unencodable property value → {:error, :invalid_record}, no echo (Rule 3).
    defp safe_props(props) do
      case safe_map_entries(props) do
        {:ok, entries} -> {:ok, entries}
        :error -> {:error, %Error{reason: :invalid_record}}
      end
    end

    @impl true
    def ready?(%Conn{} = conn), do: ping(conn)

    @impl true
    def health?(%Conn{} = conn), do: ping(conn)

    # --- Transactions (BeginTransaction/CommitTransaction/RollbackTransaction, DATA plane) ---
    # The gRPC tx is a server-side `transaction_id` (portable across separate channels — proven live:
    # begin/execute/commit each ran over their own per-call connection). `execute`/`query_stream`
    # carry it as a `TransactionContext` when `conn.session_id` is set (see transaction_context/1).
    @impl true
    def begin(%Conn{} = conn, opts) do
      req = %BeginTransactionRequest{
        database: conn.database,
        credentials: credentials(conn),
        isolation: isolation(opts[:isolation])
      }

      with_channel(conn, fn ch ->
        case ArcadeDbService.Stub.begin_transaction(ch, req, metadata: metadata(conn)) do
          {:ok, %{transaction_id: id}} when is_binary(id) and id != "" -> {:ok, id}
          {:ok, _} -> {:error, %Error{reason: :transaction_error}}
          {:error, e} -> {:error, map_error(e)}
        end
      end)
    end

    @impl true
    def commit(%Conn{session_id: sid} = conn) when is_binary(sid) do
      req = %CommitTransactionRequest{
        transaction: %TransactionContext{transaction_id: sid, database: conn.database},
        credentials: credentials(conn)
      }

      with_channel(conn, fn ch ->
        case ArcadeDbService.Stub.commit_transaction(ch, req, metadata: metadata(conn)) do
          {:ok, %{success: true}} -> :ok
          {:ok, _} -> {:error, %Error{reason: :transaction_error}}
          {:error, e} -> {:error, map_error(e)}
        end
      end)
    end

    def commit(%Conn{}), do: {:error, %Error{reason: :transaction_error}}

    @impl true
    def rollback(%Conn{session_id: sid} = conn) when is_binary(sid) do
      req = %RollbackTransactionRequest{
        transaction: %TransactionContext{transaction_id: sid, database: conn.database},
        credentials: credentials(conn)
      }

      with_channel(conn, fn ch ->
        case ArcadeDbService.Stub.rollback_transaction(ch, req, metadata: metadata(conn)) do
          {:ok, %{success: true}} -> :ok
          {:ok, _} -> {:error, %Error{reason: :transaction_error}}
          {:error, e} -> {:error, map_error(e)}
        end
      end)
    end

    def rollback(%Conn{}), do: {:error, %Error{reason: :transaction_error}}

    # --- Admin plane (ArcadeDbAdminService — authenticates by the body `credentials` field, NOT
    # metadata; live-proven: metadata-only → Unauthenticated) ---
    @impl true
    def list_databases(%Conn{} = conn) do
      with_channel(conn, fn ch ->
        req = %ListDatabasesRequest{credentials: credentials(conn)}

        case ArcadeDbAdminService.Stub.list_databases(ch, req) do
          {:ok, %{databases: dbs}} -> {:ok, dbs}
          {:error, e} -> {:error, map_error(e)}
        end
      end)
    end

    @impl true
    def database_exists?(%Conn{} = conn, name) do
      with_channel(conn, fn ch ->
        req = %ExistsDatabaseRequest{credentials: credentials(conn), name: name}

        case ArcadeDbAdminService.Stub.exists_database(ch, req) do
          {:ok, %{exists: exists}} -> {:ok, exists}
          {:error, e} -> {:error, map_error(e)}
        end
      end)
    end

    # `Arcadic.Server` builds command strings routed through `server_command`. Only the stable verbs
    # gRPC has typed RPCs for are recognized (create/drop database — the name is already
    # Identifier-validated by Server); anything else (settings, open/close/align/events/shutdown/
    # profiler/users) has NO gRPC admin RPC → value-free `:not_supported` (no command-tail echo).
    @impl true
    def server_command(%Conn{} = conn, command) when is_binary(command) do
      case parse_server_command(command) do
        {:create_database, name} -> admin_create_database(conn, name)
        {:drop_database, name} -> admin_drop_database(conn, name)
        :unsupported -> {:error, %Error{reason: :not_supported}}
      end
    end

    def server_command(%Conn{}, _command), do: {:error, %Error{reason: :not_supported}}

    # `server_get` is HTTP-path-shaped; only `/api/v1/server` (server info) maps to a gRPC RPC.
    # NOTE (gRPC divergence): GetServerInfo has no `metrics` and no `mode` — so `Server.metrics/1`
    # returns `{:ok, %{}}` and a `mode:` option is ignored over gRPC (documented in the moduledoc).
    @impl true
    def server_get(%Conn{} = conn, path) when is_binary(path) do
      if String.starts_with?(path, "/api/v1/server") do
        admin_server_info(conn)
      else
        {:error, %Error{reason: :not_supported}}
      end
    end

    def server_get(%Conn{}, _path), do: {:error, %Error{reason: :not_supported}}

    # gRPC has no token-session model (auth is metadata/body-creds) — login/logout are HTTP-only.
    @impl true
    def login(%Conn{}), do: {:error, %Error{reason: :not_supported}}
    @impl true
    def logout(%Conn{}), do: {:error, %Error{reason: :not_supported}}

    defp parse_server_command(command) do
      case command |> String.trim() |> String.split(~r/\s+/, parts: 3) do
        [verb, "database", name] ->
          case String.downcase(verb) do
            "create" -> {:create_database, name}
            "drop" -> {:drop_database, name}
            _ -> :unsupported
          end

        _ ->
          :unsupported
      end
    end

    defp admin_create_database(conn, name) do
      with_channel(conn, fn ch ->
        req = %CreateDatabaseRequest{credentials: credentials(conn), name: name}

        case ArcadeDbAdminService.Stub.create_database(ch, req) do
          {:ok, _} -> {:ok, %{}}
          {:error, e} -> {:error, map_error(e)}
        end
      end)
    end

    defp admin_drop_database(conn, name) do
      with_channel(conn, fn ch ->
        req = %DropDatabaseRequest{credentials: credentials(conn), name: name}

        case ArcadeDbAdminService.Stub.drop_database(ch, req) do
          {:ok, _} -> {:ok, %{}}
          {:error, e} -> {:error, map_error(e)}
        end
      end)
    end

    defp admin_server_info(conn) do
      with_channel(conn, fn ch ->
        req = %GetServerInfoRequest{credentials: credentials(conn)}

        case ArcadeDbAdminService.Stub.get_server_info(ch, req) do
          {:ok, info} -> {:ok, server_info_to_map(info)}
          {:error, e} -> {:error, map_error(e)}
        end
      end)
    end

    # String-keyed map matching what `Server.info` returns from the HTTP `/api/v1/server` body.
    defp server_info_to_map(info) do
      %{
        "version" => info.version,
        "edition" => info.edition,
        "httpPort" => info.http_port,
        "grpcPort" => info.grpc_port,
        "databasesCount" => info.databases_count
      }
    end

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
        {:ok, ch, mode} ->
          try do
            fun.(ch)
          after
            release(ch, mode)
          end

        {:error, e} ->
          {:error, e}
      end
    end

    # When the caller-supervised ChannelPool is running, reuse its shared endpoint channel; otherwise
    # open a fresh per-call channel (the default). `connect/1` returns the MODE (`:pooled | :per_call`)
    # so `release/2` mirrors the SAME decision even if the pool starts/stops/crashes between connect and
    # release: a pooled channel is left open (the pool owns its lifetime), a per-call channel is
    # disconnected. Deciding at release-time instead would leak a per-call channel (pool started midway)
    # or tear a shared channel out from concurrent callers (pool crashed midway).
    defp connect(%Conn{} = conn) do
      ensure_client_supervisor()

      if pool_running?() do
        tag_mode(
          ChannelPool.checkout(endpoint_key(conn), fn -> raw_connect(conn, 1) end),
          :pooled
        )
      else
        tag_mode(raw_connect(conn, 1), :per_call)
      end
    end

    defp tag_mode({:ok, ch}, mode), do: {:ok, ch, mode}
    defp tag_mode({:error, _} = err, _mode), do: err

    defp release(_ch, :pooled), do: :ok
    defp release(ch, :per_call), do: safe_disconnect(ch)

    defp pool_running?, do: Process.whereis(ChannelPool) != nil

    defp endpoint_key(%Conn{} = conn) do
      uri = URI.parse(conn.base_url)
      {uri.host || "localhost", uri.port || 50_051, tls?(conn, uri)}
    end

    # Retry the channel open ONCE on a transient failure. Opening a fresh gun HTTP/2 connection
    # can race the first-connect on a cold client supervisor; the retry (no RPC has run, so nothing
    # has a side effect yet) makes the per-call path stable under connect churn.
    defp raw_connect(%Conn{} = conn, retries) do
      uri = URI.parse(conn.base_url)
      endpoint = "#{uri.host || "localhost"}:#{uri.port || 50_051}"
      opts = if tls?(conn, uri), do: [cred: tls_credential()], else: []

      case GRPC.Stub.connect(endpoint, opts) do
        {:ok, ch} ->
          {:ok, ch}

        {:error, _reason} when retries > 0 ->
          Process.sleep(25)
          raw_connect(conn, retries - 1)

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

    # A read/write inside `transaction/3` carries the session's tx_id (stored in `conn.session_id`
    # by the Transaction facade) so the server runs it in the open transaction; nil (no session) →
    # the request's `transaction` field stays unset (autocommit), exactly as before.
    defp transaction_context(%Conn{session_id: sid, database: db}) when is_binary(sid),
      do: %TransactionContext{transaction_id: sid, database: db}

    defp transaction_context(%Conn{}), do: nil

    # `:isolation` maps to the TransactionIsolation enum; nil leaves the server default. Unknown is
    # rejected value-free (mirrors the HTTP transport's isolation_body — echo the allowed set, never
    # the offending value).
    defp isolation(nil), do: nil
    defp isolation(:read_uncommitted), do: :READ_UNCOMMITTED
    defp isolation(:read_committed), do: :READ_COMMITTED
    defp isolation(:repeatable_read), do: :REPEATABLE_READ
    defp isolation(:serializable), do: :SERIALIZABLE

    defp isolation(_other),
      do:
        raise(
          ArgumentError,
          "unknown isolation; allowed: [:read_uncommitted, :read_committed, :repeatable_read, :serializable]"
        )

    # --- value codec (Elixir <-> GrpcValue), VALUE-FREE (Rule 3) ---
    #
    # `safe_to_grpc_value/1` returns `{:ok, %GrpcValue{}} | :error` and NEVER raises on caller data:
    # an integer outside int64, a non-UTF-8 binary, or an unhandled struct returns `:error` (total
    # fallback) so the caller surfaces a value-free `:invalid_params`/`:invalid_record` rather than a
    # `Protobuf.EncodeError` whose message ECHOES the offending value (the recurring facade-leak class).
    # ONE encoder feeds every arm — params (execute/query_stream), batch_ingest records, and (later)
    # document-ingest/record rows — so a guard added here protects all of them.

    @int64_min -0x8000000000000000
    @int64_max 0x7FFFFFFFFFFFFFFF

    defp safe_encode_params(params) when is_map(params) do
      Enum.reduce_while(params, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
        with {:ok, key} <- safe_key(k), {:ok, gv} <- safe_to_grpc_value(v) do
          {:cont, {:ok, Map.put(acc, key, gv)}}
        else
          :error -> {:halt, {:error, %Error{reason: :invalid_params}}}
        end
      end)
    end

    defp safe_encode_params(_), do: {:ok, %{}}

    # A map KEY is coerced value-free too (not just the value): a non-String.Chars key (tuple, pid,
    # map, …) would raise `Protocol.UndefinedError` echoing the key, breaking the no-raise-on-caller-
    # data invariant. Allow the JSON-ish key shapes; anything else → `:error` (value-free).
    defp safe_key(k) when is_binary(k), do: {:ok, k}
    defp safe_key(k) when is_atom(k), do: {:ok, Atom.to_string(k)}
    defp safe_key(k) when is_integer(k), do: {:ok, Integer.to_string(k)}
    defp safe_key(_), do: :error

    defp safe_to_grpc_value(v) when is_boolean(v), do: {:ok, %GrpcValue{kind: {:bool_value, v}}}

    defp safe_to_grpc_value(v) when is_integer(v) and v >= @int64_min and v <= @int64_max,
      do: {:ok, %GrpcValue{kind: {:int64_value, v}}}

    # An int outside int64 has no proto representation (unlike HTTP's JSON text). Reject value-free.
    defp safe_to_grpc_value(v) when is_integer(v), do: :error

    defp safe_to_grpc_value(v) when is_float(v), do: {:ok, %GrpcValue{kind: {:double_value, v}}}

    defp safe_to_grpc_value(v) when is_binary(v) do
      if String.valid?(v), do: {:ok, %GrpcValue{kind: {:string_value, v}}}, else: :error
    end

    defp safe_to_grpc_value(nil), do: {:ok, %GrpcValue{}}

    # Temporal structs bind as ISO-8601 strings (matching the HTTP transport's Jason encoding);
    # handle them BEFORE the generic map clause so they don't serialize `__struct__` as a map.
    defp safe_to_grpc_value(%Date{} = d),
      do: {:ok, %GrpcValue{kind: {:string_value, Date.to_iso8601(d)}}}

    defp safe_to_grpc_value(%DateTime{} = d),
      do: {:ok, %GrpcValue{kind: {:string_value, DateTime.to_iso8601(d)}}}

    defp safe_to_grpc_value(%NaiveDateTime{} = d),
      do: {:ok, %GrpcValue{kind: {:string_value, NaiveDateTime.to_iso8601(d)}}}

    defp safe_to_grpc_value(v) when is_list(v) do
      case safe_reduce(v, &safe_to_grpc_value/1) do
        {:ok, vals} -> {:ok, %GrpcValue{kind: {:list_value, %GrpcList{values: vals}}}}
        :error -> :error
      end
    end

    defp safe_to_grpc_value(v) when is_map(v) and not is_struct(v) do
      case safe_map_entries(v) do
        {:ok, entries} -> {:ok, %GrpcValue{kind: {:map_value, %GrpcMap{entries: entries}}}}
        :error -> :error
      end
    end

    # Total fallback: any unhandled struct/term → value-free error (never a `__struct__`-bearing map
    # nor a raise that echoes the value).
    defp safe_to_grpc_value(_), do: :error

    defp safe_reduce(list, fun) do
      list
      |> Enum.reduce_while({:ok, []}, fn v, {:ok, acc} ->
        case fun.(v) do
          {:ok, gv} -> {:cont, {:ok, [gv | acc]}}
          :error -> {:halt, :error}
        end
      end)
      |> case do
        {:ok, acc} -> {:ok, Enum.reverse(acc)}
        :error -> :error
      end
    end

    defp safe_map_entries(map) do
      Enum.reduce_while(map, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
        with {:ok, key} <- safe_key(k), {:ok, gv} <- safe_to_grpc_value(v) do
          {:cont, {:ok, Map.put(acc, key, gv)}}
        else
          :error -> {:halt, :error}
        end
      end)
    end

    defp decode_record(%{properties: props} = rec) do
      props
      |> Map.new(fn {k, gv} -> {k, from_grpc_value(gv)} end)
      |> put_identity("@rid", rec.rid)
      |> put_identity("@type", rec.type)
    end

    # Total fallback: a server that returns `found: true` with an unset `record` (proto3 → nil), or any
    # other unexpected shape, decodes to an empty map rather than a FunctionClauseError (value-free).
    defp decode_record(_), do: %{}

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
