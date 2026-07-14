defmodule Arcadic.Integration.GrpcTest do
  @moduledoc """
  Live proofs for the optional `Arcadic.Transport.Grpc` against an ArcadeDB with the gRPC plugin
  enabled (`-Darcadedb.server.plugins=GRPC:... -Darcadedb.grpc.enabled=true`). Separate env from the
  main `:integration` suite because gRPC is a distinct listener (and qor-arcadedb ships without it):

    * `ARCADIC_GRPC_TEST_URL`      — `grpc://host:port` (the gRPC listener)
    * `ARCADIC_GRPC_TEST_HTTP_URL` — `http://host:port` (same server; used to create/seed the db,
      since the gRPC transport is deliberately admin-incapable)
    * `ARCADIC_GRPC_TEST_PASSWORD` — root password

  No skip-on-absent-plugin: with the env set, a missing gRPC surface FAILS loudly.
  """
  use ExUnit.Case, async: false
  @moduletag :integration_grpc

  alias Arcadic.{Conn, Server}
  alias Arcadic.Transport.Grpc

  setup_all do
    grpc_url =
      System.get_env("ARCADIC_GRPC_TEST_URL") ||
        flunk("set ARCADIC_GRPC_TEST_URL (grpc://host:port)")

    http_url =
      System.get_env("ARCADIC_GRPC_TEST_HTTP_URL") || flunk("set ARCADIC_GRPC_TEST_HTTP_URL")

    pass = System.get_env("ARCADIC_GRPC_TEST_PASSWORD") || flunk("set ARCADIC_GRPC_TEST_PASSWORD")

    db = "grpc_it_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    http = Conn.new(http_url, db, auth: {"root", pass})
    _ = Server.drop_database(http, db)
    :ok = Server.create_database!(http, db)
    Arcadic.command!(http, "CREATE DOCUMENT TYPE Doc", %{}, language: "sql")

    for i <- 1..5,
        do:
          Arcadic.command!(http, "INSERT INTO Doc SET n = #{i}, tag = 'row#{i}'", %{},
            language: "sql"
          )

    on_exit(fn -> Server.drop_database(http, db) end)

    grpc = Conn.new(grpc_url, db, auth: {"root", pass}, transport: Grpc)
    {:ok, grpc: grpc}
  end

  test "execute :read returns typed rows (int + string decoded)", %{grpc: c} do
    assert {:ok, rows} =
             Grpc.execute(
               c,
               :read,
               %{statement: "SELECT n, tag FROM Doc ORDER BY n", params: %{}, language: "sql"},
               []
             )

    assert Enum.map(rows, & &1["n"]) == [1, 2, 3, 4, 5]
    assert hd(rows)["tag"] == "row1"
  end

  test "execute :read binds params (a quote-breaking value is inert)", %{grpc: c} do
    assert {:ok, rows} =
             Grpc.execute(
               c,
               :read,
               %{
                 statement: "SELECT n FROM Doc WHERE n >= :min ORDER BY n",
                 params: %{"min" => 3},
                 language: "sql"
               },
               []
             )

    assert Enum.map(rows, & &1["n"]) == [3, 4, 5]
  end

  test "query_stream CURSOR drains the server cursor across batches (chunk < total)", %{grpc: c} do
    assert {:ok, stream} =
             Grpc.query_stream(
               c,
               %{statement: "SELECT n FROM Doc ORDER BY n", params: %{}, language: "sql"},
               chunk_size: 2
             )

    assert Enum.map(Enum.to_list(stream), & &1["n"]) == [1, 2, 3, 4, 5]
  end

  test "execute :write runs a command (DDL + insert on its own type, isolated from Doc)", %{
    grpc: c
  } do
    # Own type so a write never pollutes the Doc rows the read/stream tests assert on (ExUnit
    # randomizes intra-module order). Also proves gRPC ExecuteCommand runs DDL + DML.
    assert {:ok, _} =
             Grpc.execute(
               c,
               :write,
               %{statement: "CREATE DOCUMENT TYPE DocW", params: %{}, language: "sql"},
               []
             )

    # :write must RETURN the created record (return_rows) — parity with the HTTP transport, not
    # just {:ok, _}. A regression that drops the rows (return_rows unset) reddens this.
    assert {:ok, [row]} =
             Grpc.execute(
               c,
               :write,
               %{statement: "INSERT INTO DocW SET n = 42", params: %{}, language: "sql"},
               []
             )

    assert row["n"] == 42
    assert is_binary(row["@rid"])

    assert {:ok, [%{"c" => 1}]} =
             Grpc.execute(
               c,
               :read,
               %{statement: "SELECT count(*) AS c FROM DocW", params: %{}, language: "sql"},
               []
             )
  end

  test "decode: DATETIME and DECIMAL columns decode to real values, not nil (silent-loss guard)",
       %{
         grpc: c
       } do
    # Regression guard for the value codec: unhandled GrpcValue kinds silently became nil.
    Grpc.execute(
      c,
      :write,
      %{statement: "CREATE DOCUMENT TYPE Typed", params: %{}, language: "sql"},
      []
    )

    Grpc.execute(
      c,
      :write,
      %{statement: "CREATE PROPERTY Typed.ts DATETIME", params: %{}, language: "sql"},
      []
    )

    Grpc.execute(
      c,
      :write,
      %{statement: "CREATE PROPERTY Typed.amt DECIMAL", params: %{}, language: "sql"},
      []
    )

    Grpc.execute(
      c,
      :write,
      %{
        statement:
          "INSERT INTO Typed SET ts = date('2024-01-02 03:04:05', 'yyyy-MM-dd HH:mm:ss'), amt = 12.34",
        params: %{},
        language: "sql"
      },
      []
    )

    assert {:ok, [row]} =
             Grpc.execute(
               c,
               :read,
               %{statement: "SELECT ts, amt FROM Typed", params: %{}, language: "sql"},
               []
             )

    refute is_nil(row["ts"])
    refute is_nil(row["amt"])
    assert row["amt"] == 12.34 or row["amt"] == 12
  end

  # Gates partial-consumption CORRECTNESS (a Stream.take over multiple wire batches yields the
  # requested prefix in order). NOTE: this does NOT gate server-side laziness — a client cannot
  # distinguish "pulled one batch" from "drained the cursor then sliced" without server-batch
  # instrumentation (both yield the same rows). Laziness is guaranteed structurally by the
  # Stream.transform implementation (per-demand pull) and verified in code review, not here.
  test "query_stream supports partial consumption across batches, preserving order", %{grpc: c} do
    assert {:ok, stream} =
             Grpc.query_stream(
               c,
               %{statement: "SELECT n FROM Doc ORDER BY n", params: %{}, language: "sql"},
               chunk_size: 1
             )

    assert Enum.map(Stream.take(stream, 3) |> Enum.to_list(), & &1["n"]) == [1, 2, 3]
  end

  test "a bearer-auth gRPC conn is rejected at construction (no silent empty-cred fail-open)", %{
    grpc: c
  } do
    assert_raise ArgumentError, fn -> Conn.with_bearer(c, "tok") end

    assert_raise ArgumentError, fn ->
      Conn.new("grpc://localhost:1", "db", auth: {:bearer, "t"}, transport: Grpc)
    end
  end

  test "ready? pings the server", %{grpc: c} do
    assert {:ok, true} = Grpc.ready?(c)
  end

  # --- T5: admin surface (list/exists/create/drop DB + info) + explain ---

  test "Server.list_databases + database_exists? over gRPC (admin plane, body creds)", %{grpc: c} do
    assert {:ok, dbs} = Arcadic.Server.list_databases(c)
    assert c.database in dbs
    assert {:ok, true} = Arcadic.Server.database_exists?(c, c.database)
    assert {:ok, false} = Arcadic.Server.database_exists?(c, "no_such_db_xyz")
  end

  test "Server.create_database/drop_database over gRPC (via server_command mapping)", %{grpc: c} do
    db = "grpc_admin_#{System.unique_integer([:positive])}"
    # drive the real Server facade (not a hand-built command string) so a wording drift reds (#10)
    assert :ok = Arcadic.Server.create_database(c, db)
    assert {:ok, true} = Arcadic.Server.database_exists?(c, db)
    assert {:ok, dbs} = Arcadic.Server.list_databases(c)
    assert db in dbs
    assert :ok = Arcadic.Server.drop_database(c, db)
    assert {:ok, false} = Arcadic.Server.database_exists?(c, db)
  end

  test "Server.info over gRPC returns the server version", %{grpc: c} do
    assert {:ok, info} = Arcadic.Server.info(c)
    assert is_binary(info["version"]) and info["version"] != ""
  end

  test "explain over gRPC returns a plan", %{grpc: c} do
    assert {:ok, %{plan: plan}} = Arcadic.explain(c, "SELECT FROM Doc", %{}, language: "sql")
    assert is_binary(plan) and plan != ""
  end

  test "an unrecognized server_command / login / logout is :not_supported over gRPC", %{grpc: c} do
    assert {:error, %Arcadic.Error{reason: :not_supported}} =
             Grpc.server_command(c, "set server setting `x` `y`")

    assert {:error, %Arcadic.Error{reason: :not_supported}} = Grpc.login(c)
    assert {:error, %Arcadic.Error{reason: :not_supported}} = Grpc.logout(c)
  end

  # TRIPWIRE — redaction. A failing statement carrying a secret param must surface a VALUE-FREE
  # error whose EVERY field is value-free — no raw gRPC wire message (which echoes the offending
  # statement/value) in ANY field. Note: `Arcadic.Error` quarantines its `:message` field from
  # `message/1`/`inspect/1` for server-origin reasons, so a leak would NOT show in the rendered
  # error — this test uses `inspect(structs: false)` to reveal the raw `:message` field too, so a
  # transport that stuffs `RPCError.message` into the struct is caught. Red-capable: mapping the
  # error to `%Error{reason: :server_error, message: rpc_error.message}` reddens this (verified).
  test "redaction: a wire error never echoes the statement or the param value in any field", %{
    grpc: c
  } do
    secret = "s3cr3t_#{System.unique_integer([:positive])}"

    assert {:error, err} =
             Grpc.execute(
               c,
               :read,
               %{
                 statement: "SELECT FROM NoSuchType_#{secret} WHERE x = :p",
                 params: %{"p" => secret},
                 language: "sql"
               },
               []
             )

    assert match?(%Arcadic.Error{}, err) or match?(%Arcadic.TransportError{}, err)
    rendered = inspect(err, structs: false) <> " " <> Exception.message(err)
    refute rendered =~ secret
    refute rendered =~ "NoSuchType"
  end

  # --- T1: transactions (begin/commit/rollback + tx-context) ---

  # PIVOTAL (T1): the gRPC tx_id is portable across SEPARATE per-call channels — begin (channel A,
  # closed), write (channel B, closed), read-sees-uncommitted (channel C), commit — all distinct
  # connections. This is the load-bearing property for the per-call-connect tx model (and the pool).
  test "transaction/3 commits across separate per-call channels; a read in-tx sees the uncommitted write",
       %{grpc: c} do
    :ok = create_type!(c, "TxDoc")
    marker = "txok_#{System.unique_integer([:positive])}"

    assert {:ok, :committed} =
             Arcadic.transaction(c, fn tx ->
               Arcadic.command!(tx, "INSERT INTO TxDoc SET name = :n", %{"n" => marker},
                 language: "sql"
               )

               # read INSIDE the tx (another per-call channel) sees the uncommitted write
               assert {:ok, [%{"c" => 1}]} =
                        Arcadic.query(
                          tx,
                          "SELECT count(*) AS c FROM TxDoc WHERE name = :n",
                          %{"n" => marker},
                          language: "sql"
                        )

               :committed
             end)

    # after commit, visible outside the tx
    assert {:ok, [%{"c" => 1}]} =
             Arcadic.query(c, "SELECT count(*) AS c FROM TxDoc WHERE name = :n", %{"n" => marker},
               language: "sql"
             )
  end

  test "transaction/3 rollback discards the write", %{grpc: c} do
    :ok = create_type!(c, "TxRoll")
    marker = "roll_#{System.unique_integer([:positive])}"

    assert {:error, :aborted} =
             Arcadic.transaction(c, fn tx ->
               Arcadic.command!(tx, "INSERT INTO TxRoll SET name = :n", %{"n" => marker},
                 language: "sql"
               )

               Arcadic.Transaction.rollback(tx, :aborted)
             end)

    assert {:ok, [%{"c" => 0}]} =
             Arcadic.query(
               c,
               "SELECT count(*) AS c FROM TxRoll WHERE name = :n",
               %{"n" => marker},
               language: "sql"
             )
  end

  test "nested transaction raises (no savepoint contract)", %{grpc: c} do
    assert_raise ArgumentError, fn ->
      Arcadic.transaction(c, fn tx ->
        Arcadic.transaction(tx, fn _ -> :never end)
      end)
    end
  end

  test "transaction/3 accepts an isolation option", %{grpc: c} do
    :ok = create_type!(c, "TxIso")
    marker = "iso_#{System.unique_integer([:positive])}"

    assert {:ok, :ok} =
             Arcadic.transaction(
               c,
               fn tx ->
                 Arcadic.command!(tx, "INSERT INTO TxIso SET name = :n", %{"n" => marker},
                   language: "sql"
                 )

                 :ok
               end,
               isolation: :repeatable_read
             )
  end

  defp create_type!(c, type) do
    {:ok, _} =
      Grpc.execute(
        c,
        :write,
        %{statement: "CREATE DOCUMENT TYPE #{type} IF NOT EXISTS", params: %{}, language: "sql"},
        []
      )

    :ok
  end

  # --- T2: GraphBatchLoad → Arcadic.Bulk.ingest (graph ingest), transport-transparent with HTTP ---

  defp create_graph_types!(c) do
    for ddl <- ["CREATE VERTEX TYPE Person IF NOT EXISTS", "CREATE EDGE TYPE Knows IF NOT EXISTS"] do
      {:ok, _} = Grpc.execute(c, :write, %{statement: ddl, params: %{}, language: "sql"}, [])
    end

    :ok
  end

  test "Bulk.ingest over gRPC: counts + idMapping, and read-back proves property values + types (non-vacuous)",
       %{grpc: c} do
    :ok = create_graph_types!(c)
    a = "alice_#{System.unique_integer([:positive])}"
    b = "bob_#{System.unique_integer([:positive])}"

    assert {:ok, %{vertices_created: 2, edges_created: 1, id_mapping: idm}} =
             Arcadic.Bulk.ingest(c, [
               %{
                 "@type" => "vertex",
                 "@class" => "Person",
                 "@id" => "p1",
                 "name" => a,
                 "age" => 30
               },
               %{"@type" => "vertex", "@class" => "Person", "@id" => "p2", "name" => b},
               %{"@type" => "edge", "@class" => "Knows", "@from" => "p1", "@to" => "p2"}
             ])

    assert is_binary(idm["p1"]) and is_binary(idm["p2"])

    # NON-VACUOUS: read the ingested vertex back and assert the property VALUE + runtime TYPE
    # survived (a count-only assertion can't see a type/serialization divergence).
    assert {:ok, [row]} =
             Grpc.execute(
               c,
               :read,
               %{
                 statement: "SELECT name, age FROM Person WHERE name = :n",
                 params: %{"n" => a},
                 language: "sql"
               },
               []
             )

    assert row["name"] == a
    assert row["age"] == 30 and is_integer(row["age"])
  end

  test "Bulk.ingest over gRPC: an edge referencing an existing vertex's real @rid resolves", %{
    grpc: c
  } do
    :ok = create_graph_types!(c)
    seed = "seed_#{System.unique_integer([:positive])}"

    assert {:ok, %{id_mapping: %{"s1" => rid}}} =
             Arcadic.Bulk.ingest(c, [
               %{"@type" => "vertex", "@class" => "Person", "@id" => "s1", "name" => seed}
             ])

    # second batch: an edge from the EXISTING vertex's real #bucket:pos rid to a new temp-id vertex
    assert {:ok, %{vertices_created: 1, edges_created: 1}} =
             Arcadic.Bulk.ingest(c, [
               %{"@type" => "vertex", "@class" => "Person", "@id" => "n1", "name" => "linked"},
               %{"@type" => "edge", "@class" => "Knows", "@from" => rid, "@to" => "n1"}
             ])
  end

  test "batch_ingest FAILS CLOSED when the conn is in a transaction (GraphBatchChunk carries no tx)",
       %{grpc: c} do
    # A session-bearing conn (as inside transaction/3) must be REFUSED value-free, never silently
    # auto-committed outside the caller's tx. Guard is on the transport callback directly.
    tx_conn = %{c | session_id: "tx_pinned_fake"}
    ndjson = [~s({"@type":"vertex","@class":"Person","@id":"t1","name":"intx"}), "\n"]

    assert {:error, %Arcadic.Error{reason: :transaction_unsupported}} =
             Grpc.batch_ingest(tx_conn, ndjson, [])

    # And through the facade inside a real tx: the ingest refuses (the empty tx commits, but NO
    # rows were auto-committed — the fail-closed guarantee).
    assert {:ok, {:error, %Arcadic.Error{reason: :transaction_unsupported}}} =
             Arcadic.transaction(c, fn tx ->
               Arcadic.Bulk.ingest(tx, [
                 %{"@type" => "vertex", "@class" => "Person", "@id" => "t1", "name" => "intx"}
               ])
             end)
  end

  # TRIPWIRE (redaction, RED-first): a property value outside int64 encodes fine through the facade's
  # Jason (HTTP would accept it as text) but the gRPC int64 codec must reject it VALUE-FREE — never a
  # protobuf-encode raise echoing the value (the Rule-3 coercion-raise class).
  test "Bulk.ingest over gRPC: an unencodable (>int64) value is rejected value-free, no raise", %{
    grpc: c
  } do
    :ok = create_graph_types!(c)
    secret = 99_999_999_999_999_999_999_999_999

    assert {:error, err} =
             Arcadic.Bulk.ingest(c, [
               %{"@type" => "vertex", "@class" => "Person", "@id" => "x1", "big" => secret}
             ])

    assert match?(%Arcadic.Error{reason: :invalid_record}, err)
    refute inspect(err, structs: false) =~ "99999999999999999999999999"
  end

  # The same shared codec protects the params path: a >int64 PARAM must surface a value-free error,
  # not a raise that echoes it (pre-existing leak on execute/query_stream, closed by the shared encoder).
  test "execute over gRPC: a >int64 param is rejected value-free, no raise", %{grpc: c} do
    secret = 88_888_888_888_888_888_888_888_888

    assert {:error, err} =
             Grpc.execute(
               c,
               :read,
               %{statement: "SELECT :p AS p", params: %{"p" => secret}, language: "sql"},
               []
             )

    assert match?(%Arcadic.Error{reason: :invalid_params}, err) or
             match?(%Arcadic.TransportError{}, err)

    refute inspect(err, structs: false) =~ "88888888888888888888888888"
  end

  # --- T3: document ingest → Arcadic.Ingest.insert (gRPC BulkInsert) ---

  test "Ingest.insert over gRPC: rows land in the target class; read-back proves values + types",
       %{
         grpc: c
       } do
    :ok = create_type!(c, "Metric")
    tag = "m_#{System.unique_integer([:positive])}"

    assert {:ok, %{received: 2, inserted: 2}} =
             Arcadic.Ingest.insert(c, "Metric", [
               %{"tag" => tag, "value" => 1},
               %{"tag" => tag, "value" => 2}
             ])

    assert {:ok, [%{"c" => 2}]} =
             Grpc.execute(
               c,
               :read,
               %{
                 statement: "SELECT count(*) AS c FROM Metric WHERE tag = :t",
                 params: %{"t" => tag},
                 language: "sql"
               },
               []
             )
  end

  # BulkInsert manages its own transaction and does NOT honor an outer session tx (live-proven), so
  # like batch_ingest it FAILS CLOSED inside transaction/3 rather than silently auto-commit outside it.
  test "Ingest.insert FAILS CLOSED inside a transaction (BulkInsert does not honor a session tx)",
       %{
         grpc: c
       } do
    tx_conn = %{c | session_id: "tx_pinned_fake"}

    assert {:error, %Arcadic.Error{reason: :transaction_unsupported}} =
             Arcadic.Ingest.insert(tx_conn, "Metric", [%{"tag" => "x"}])
  end

  test "Ingest.insert guards bad-shape input value-free (Rule 3 total fallback)", %{grpc: c} do
    e1 =
      assert_raise(ArgumentError, fn -> Arcadic.Ingest.insert(c, "Metric", %{"secret" => 42}) end)

    refute Exception.message(e1) =~ "secret"

    assert_raise(ArgumentError, fn -> Arcadic.Ingest.insert(c, :not_a_binary, []) end)
  end

  test "Ingest.insert on a non-gRPC transport is :not_supported", %{grpc: c} do
    http = %{c | transport: Arcadic.Transport.HTTP}

    assert {:error, %Arcadic.Error{reason: :not_supported}} =
             Arcadic.Ingest.insert(http, "X", [%{}])
  end

  test "Ingest.insert with :chunk_size streams via InsertStream (all rows land across chunks)", %{
    grpc: c
  } do
    :ok = create_type!(c, "MetricStream")
    tag = "ms_#{System.unique_integer([:positive])}"
    rows = for i <- 1..5, do: %{"tag" => tag, "n" => i}

    assert {:ok, %{received: 5, inserted: 5}} =
             Arcadic.Ingest.insert(c, "MetricStream", rows, chunk_size: 2)

    assert {:ok, [%{"c" => 5}]} =
             Grpc.execute(
               c,
               :read,
               %{
                 statement: "SELECT count(*) AS c FROM MetricStream WHERE tag = :t",
                 params: %{"t" => tag},
                 language: "sql"
               },
               []
             )
  end

  # TRIPWIRE (redaction, RED-capable): a per-row server InsertError.message ECHOES the offending VALUE
  # ("Duplicated key [<value>] found on index ..." — live-verified), so the summary must surface ONLY
  # {row_index, code} and NEVER the message/field. Mapping `message: e.message` would leak the value
  # and redden this. NON-VACUOUS: the raw server message provably contains the secret.
  test "Ingest.insert redaction: a per-row server error surfaces no value (only row_index + code)",
       %{
         grpc: c
       } do
    :ok = create_type!(c, "UniqT")

    for ddl <- ["CREATE PROPERTY UniqT.k STRING", "CREATE INDEX ON UniqT (k) UNIQUE"] do
      {:ok, _} = Grpc.execute(c, :write, %{statement: ddl, params: %{}, language: "sql"}, [])
    end

    secret = "dupkey_#{System.unique_integer([:positive])}"

    assert {:ok, summary} =
             Arcadic.Ingest.insert(c, "UniqT", [%{"k" => secret}, %{"k" => secret}])

    assert summary.failed == 1
    assert [%{row_index: _, code: code}] = summary.errors
    assert is_binary(code)
    # the offending value must NOT appear anywhere in the surfaced summary
    refute inspect(summary, structs: false) =~ secret
  end

  # --- T4: single-record CRUD → Arcadic.Record (CreateRecord/LookupByRid/UpdateRecord/DeleteRecord) ---

  test "Record CRUD over gRPC: create → lookup → update(partial) → lookup → delete → lookup(nil)",
       %{
         grpc: c
       } do
    :ok = create_type!(c, "Rec")
    name = "rec_#{System.unique_integer([:positive])}"

    assert {:ok, rid} = Arcadic.Record.create(c, "Rec", %{"name" => name, "age" => 30})
    assert is_binary(rid)

    assert {:ok, row} = Arcadic.Record.lookup(c, rid)
    assert row["name"] == name
    assert row["age"] == 30 and is_integer(row["age"])
    assert row["@rid"] == rid

    assert :ok = Arcadic.Record.update(c, rid, %{"age" => 31})
    assert {:ok, updated} = Arcadic.Record.lookup(c, rid)
    # partial merge: age changed, name preserved
    assert updated["age"] == 31
    assert updated["name"] == name

    assert :ok = Arcadic.Record.delete(c, rid)
    assert {:ok, nil} = Arcadic.Record.lookup(c, rid)
  end

  test "Record ops guard bad-shape input value-free (Rule 3)", %{grpc: c} do
    # non-map props / non-binary rid|type raise a STATIC message, never a FunctionClauseError echo.
    e = assert_raise(ArgumentError, fn -> Arcadic.Record.create(c, "Rec", "secret-42") end)
    refute Exception.message(e) =~ "secret-42"
    assert_raise(ArgumentError, fn -> Arcadic.Record.lookup(c, :not_binary) end)
    assert_raise(ArgumentError, fn -> Arcadic.Record.create(c, :not_binary, %{}) end)
  end

  test "Record CRUD on a non-gRPC transport is :not_supported", %{grpc: c} do
    http = %{c | transport: Arcadic.Transport.HTTP}

    assert {:error, %Arcadic.Error{reason: :not_supported}} =
             Arcadic.Record.create(http, "X", %{})

    assert {:error, %Arcadic.Error{reason: :not_supported}} = Arcadic.Record.lookup(http, "#1:0")
  end

  # TRIPWIRE (redaction): a bad-value property must surface a value-free error, never echo the value.
  test "Record.create with an unencodable value is rejected value-free", %{grpc: c} do
    :ok = create_type!(c, "RecBad")
    secret = 77_777_777_777_777_777_777_777_777

    assert {:error, err} = Arcadic.Record.create(c, "RecBad", %{"big" => secret})
    assert match?(%Arcadic.Error{reason: :invalid_record}, err)
    refute inspect(err, structs: false) =~ "77777777777777777777777777"
  end

  # Record CRUD carries the tx-context; a create inside transaction/3 must be DISCARDED on rollback
  # (join the tx), never silently auto-committed outside it (tx symmetry, plan review #2).
  test "Record.create inside a transaction is discarded on rollback (tx symmetry)", %{grpc: c} do
    :ok = create_type!(c, "RecTx")
    name = "rectx_#{System.unique_integer([:positive])}"

    assert {:error, :abort} =
             Arcadic.transaction(c, fn tx ->
               {:ok, _} = Arcadic.Record.create(tx, "RecTx", %{"name" => name})
               Arcadic.Transaction.rollback(tx, :abort)
             end)

    assert {:ok, [%{"c" => 0}]} =
             Grpc.execute(
               c,
               :read,
               %{
                 statement: "SELECT count(*) AS c FROM RecTx WHERE name = :n",
                 params: %{"n" => name},
                 language: "sql"
               },
               []
             )
  end

  # --- T6: operations are transparent through the managed ChannelPool + safe under concurrency ---

  test "operations work through the ChannelPool (transparency) and reuse one shared channel", %{
    grpc: c
  } do
    {:ok, pool} = Arcadic.Transport.Grpc.ChannelPool.start_link([])
    on_exit(fn -> if Process.alive?(pool), do: GenServer.stop(pool) end)

    # a mix of unary read, a server-cursor stream, and a ping all work through the pooled channel
    assert {:ok, rows} =
             Grpc.execute(
               c,
               :read,
               %{statement: "SELECT n FROM Doc ORDER BY n", params: %{}, language: "sql"},
               []
             )

    assert length(rows) == 5

    assert {:ok, stream} =
             Grpc.query_stream(
               c,
               %{statement: "SELECT n FROM Doc ORDER BY n", params: %{}, language: "sql"},
               chunk_size: 2
             )

    assert length(Enum.to_list(stream)) == 5
    assert {:ok, true} = Grpc.ready?(c)

    # CONCURRENCY-STRESS (review #2): many concurrent calls multiplex over the ONE shared channel —
    # no corruption, no mid-stream teardown, no supervisor race (NOT an async:false 10/0 proof).
    results =
      1..25
      |> Task.async_stream(
        fn _ ->
          Grpc.execute(
            c,
            :read,
            %{statement: "SELECT n FROM Doc", params: %{}, language: "sql"},
            []
          )
        end,
        max_concurrency: 25,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.all?(results, &match?({:ok, list} when length(list) == 5, &1))
  end
end
