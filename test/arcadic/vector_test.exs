defmodule Arcadic.VectorTest do
  use ExUnit.Case, async: true
  alias Arcadic.{Conn, Vector}

  defp conn,
    do:
      Conn.new("http://arcade.invalid", "mydb",
        auth: {"root", "x"},
        transport_options: [plug: {Req.Test, __MODULE__}]
      )

  describe "index_ref/2" do
    test "composes the server-derived ref for valid identifiers" do
      assert {:ok, "Doc[embedding]"} = Vector.index_ref("Doc", "embedding")
    end

    test "rejects a bad type or property value-free (no ref leaked)" do
      assert {:error, :invalid_identifier} = Vector.index_ref("Doc]; DROP", "embedding")
      assert {:error, :invalid_identifier} = Vector.index_ref("Doc", "embedding]; x")
      assert {:error, :invalid_identifier} = Vector.index_ref("Doc", "weird-name?")
    end
  end

  describe "create_dense_index/5" do
    test "emits CREATE INDEX IF NOT EXISTS with required + optional METADATA, language sql" do
      Req.Test.stub(__MODULE__, fn c ->
        send(self(), {:cmd, c.request_path, Jason.decode!(Req.Test.raw_body(c))})
        Req.Test.json(c, %{"result" => [%{"operation" => "create index"}]})
      end)

      assert :ok =
               Vector.create_dense_index(conn(), "Doc", "embedding", 1536,
                 similarity: :cosine,
                 encoding: :float32,
                 quantization: :none,
                 max_connections: 16,
                 beam_width: 100
               )

      assert_received {:cmd, "/api/v1/command/mydb", %{"language" => "sql", "command" => cmd}}

      assert cmd ==
               "CREATE INDEX IF NOT EXISTS ON Doc (embedding) LSM_VECTOR METADATA " <>
                 "{dimensions:1536, similarity:'COSINE', maxConnections:16, beamWidth:100, " <>
                 "encoding:'FLOAT32', quantization:'NONE'}"
    end

    test "defaults: similarity cosine, maxConnections 16, beamWidth 100; no encoding/quantization" do
      Req.Test.stub(__MODULE__, fn c ->
        send(self(), {:cmd, Jason.decode!(Req.Test.raw_body(c))["command"]})
        Req.Test.json(c, %{"result" => [%{}]})
      end)

      assert :ok = Vector.create_dense_index(conn(), "Doc", "embedding", 3)

      assert_received {:cmd,
                       "CREATE INDEX IF NOT EXISTS ON Doc (embedding) LSM_VECTOR METADATA " <>
                         "{dimensions:3, similarity:'COSINE', maxConnections:16, beamWidth:100}"}
    end

    test "validates the identifier BEFORE any request (no stub → a request would error loudly)" do
      assert {:error, :invalid_identifier} =
               Vector.create_dense_index(conn(), "Doc; DROP", "embedding", 3)
    end

    test "rejects an unknown metadata opt key value-free (server would silently swallow it)" do
      assert_raise ArgumentError, ~r/unknown option/, fn ->
        Vector.create_dense_index(conn(), "Doc", "embedding", 3, encodng: :float32)
      end
    end

    test "rejects bad enum / non-integer values value-free (no value echoed)" do
      # bind the error the OFFENDING value flowed through, so the refute can go red
      # if that validator ever echoes the value (the redaction Critical Rule, D9).
      sim_err =
        assert_raise ArgumentError, fn ->
          Vector.create_dense_index(conn(), "Doc", "embedding", 3, similarity: :manhattan)
        end

      assert sim_err.message =~ "similarity"
      refute sim_err.message =~ "manhattan"

      dim_err =
        assert_raise ArgumentError, fn ->
          Vector.create_dense_index(conn(), "Doc", "embedding", 0)
        end

      assert dim_err.message =~ "dimensions"
      refute dim_err.message =~ "0"
    end

    test "create_dense_index! raises on a server error" do
      Req.Test.stub(__MODULE__, fn c ->
        c
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"error" => "boom", "exception" => "com.arcadedb.index.IndexException"})
      end)

      assert_raise Arcadic.Error, fn ->
        Vector.create_dense_index!(conn(), "Doc", "embedding", 3)
      end
    end
  end

  describe "drop_dense_index/3" do
    test "emits DROP INDEX with the backtick-quoted derived name + IF EXISTS" do
      Req.Test.stub(__MODULE__, fn c ->
        send(self(), {:cmd, Jason.decode!(Req.Test.raw_body(c))})
        Req.Test.json(c, %{"result" => [%{"operation" => "drop index"}]})
      end)

      assert :ok = Vector.drop_dense_index(conn(), "Doc", "embedding")

      assert_received {:cmd,
                       %{
                         "language" => "sql",
                         "command" => "DROP INDEX `Doc[embedding]` IF EXISTS"
                       }}
    end

    test "validates identifiers BEFORE any request" do
      assert {:error, :invalid_identifier} = Vector.drop_dense_index(conn(), "Doc`x", "embedding")
    end
  end

  describe "neighbors/6" do
    test "hits /query with the vector, k, and opts bound as params (never interpolated)" do
      Req.Test.stub(__MODULE__, fn c ->
        send(self(), {:req, c.request_path, Jason.decode!(Req.Test.raw_body(c))})

        Req.Test.json(c, %{
          "result" => [%{"@rid" => "#1:0", "distance" => 0.0, "@props" => "distance:4"}]
        })
      end)

      # match on +0.0 (not 0.0) — OTP 28 warns on pattern-matching the bare float 0.0
      assert {:ok, [%{"@rid" => "#1:0", "distance" => +0.0}]} =
               Vector.neighbors(conn(), "Doc", "embedding", [1.0, 0.0, 0.0], 5,
                 ef_search: 200,
                 max_distance: 0.3
               )

      assert_received {:req, "/api/v1/query/mydb", body}
      assert body["language"] == "sql"

      assert body["command"] ==
               "SELECT expand(vector.neighbors('Doc[embedding]', :vec, :k, {efSearch: :ef, maxDistance: :md}))"

      # params-only tripwire: the vector and k are in params, NOT the statement string
      assert body["params"] == %{"vec" => [1.0, 0.0, 0.0], "k" => 5, "ef" => 200, "md" => 0.3}
      refute body["command"] =~ "1.0"
    end

    test "omits the opts object when no ef_search/max_distance given" do
      Req.Test.stub(__MODULE__, fn c ->
        send(self(), {:cmd, Jason.decode!(Req.Test.raw_body(c))["command"]})
        Req.Test.json(c, %{"result" => []})
      end)

      assert {:ok, []} = Vector.neighbors(conn(), "Doc", "embedding", [1.0, 0.0], 3)
      assert_received {:cmd, "SELECT expand(vector.neighbors('Doc[embedding]', :vec, :k))"}
    end

    test "validates identifiers and value-free-rejects a bad k / non-list vector" do
      assert {:error, :invalid_identifier} =
               Vector.neighbors(conn(), "Doc]", "embedding", [1.0], 3)

      assert_raise ArgumentError, ~r/k must be a positive integer/, fn ->
        Vector.neighbors(conn(), "Doc", "embedding", [1.0], 0)
      end

      assert_raise ArgumentError, ~r/query_vector/, fn ->
        Vector.neighbors(conn(), "Doc", "embedding", "not-a-list", 3)
      end
    end

    test "rejects an unknown query opt key" do
      assert_raise ArgumentError, ~r/unknown option/, fn ->
        Vector.neighbors(conn(), "Doc", "embedding", [1.0], 3, ef_serch: 100)
      end
    end

    test "rejects malformed opts value-free (improper keyword list / map)" do
      # an improper keyword list carrying a caller value in the offending entry must NOT
      # leak it — Keyword.keys/1 would echo the entry (Rule 3, shared validate_opt_keys!).
      improper =
        assert_raise ArgumentError, fn ->
          Vector.neighbors(conn(), "Doc", "embedding", [1.0], 3, [{"SEKRIT_KEY", "PII"}])
        end

      assert improper.message =~ "keyword list"
      refute improper.message =~ "SEKRIT_KEY"
      refute improper.message =~ "PII"

      # a non-list opts (map) must raise the controlled value-free ArgumentError,
      # not a FunctionClauseError — and must not echo the value.
      map_opts =
        assert_raise ArgumentError, fn ->
          Vector.create_dense_index(conn(), "Doc", "embedding", 3, %{secret: "PII"})
        end

      assert map_opts.message =~ "keyword list"
      refute map_opts.message =~ "PII"
    end

    test "builds the opts object with only max_distance when ef_search omitted" do
      Req.Test.stub(__MODULE__, fn c ->
        send(self(), {:cmd, Jason.decode!(Req.Test.raw_body(c))})
        Req.Test.json(c, %{"result" => []})
      end)

      assert {:ok, []} = Vector.neighbors(conn(), "Doc", "embedding", [1.0], 3, max_distance: 0.3)

      assert_received {:cmd, body}

      assert body["command"] ==
               "SELECT expand(vector.neighbors('Doc[embedding]', :vec, :k, {maxDistance: :md}))"

      assert body["params"] == %{"vec" => [1.0], "k" => 3, "md" => 0.3}
    end

    test "filter binds a non-empty RID list as a param and restricts (never interpolated)" do
      Req.Test.stub(__MODULE__, fn c ->
        send(self(), {:req, Jason.decode!(Req.Test.raw_body(c))})
        Req.Test.json(c, %{"result" => []})
      end)

      assert {:ok, []} =
               Vector.neighbors(conn(), "Doc", "embedding", [1.0, 0.0, 0.0], 5,
                 filter: ["#1:0", "#1:2"]
               )

      assert_received {:req, body}

      assert body["command"] ==
               "SELECT expand(vector.neighbors('Doc[embedding]', :vec, :k, {filter: :rids}))"

      assert body["params"] == %{"vec" => [1.0, 0.0, 0.0], "k" => 5, "rids" => ["#1:0", "#1:2"]}
      refute body["command"] =~ "#1:0"
    end

    test "empty filter list raises value-free (the server silently ignores it = bypass)" do
      err =
        assert_raise ArgumentError, fn ->
          Vector.neighbors(conn(), "Doc", "embedding", [1.0], 3, filter: [])
        end

      assert err.message =~ "non-empty"
    end

    test "malformed RID in filter raises value-free (no RID echoed)" do
      err =
        assert_raise ArgumentError, fn ->
          Vector.neighbors(conn(), "Doc", "embedding", [1.0], 3, filter: ["not-a-rid"])
        end

      assert err.message =~ "RID"
      refute err.message =~ "not-a-rid"
    end
  end

  describe "fuse/3" do
    test "composes N validated neighbour subqueries with distinct indexed params + fusion strategy" do
      Req.Test.stub(__MODULE__, fn c ->
        send(self(), {:req, Jason.decode!(Req.Test.raw_body(c))})
        Req.Test.json(c, %{"result" => [%{"@rid" => "#1:0"}]})
      end)

      assert {:ok, [%{"@rid" => "#1:0"}]} =
               Vector.fuse(
                 conn(),
                 [{"Doc", "embedding", [1.0, 0.0], 3}, {"Doc", "embedding", [0.0, 1.0], 3}],
                 fusion: :rrf
               )

      assert_received {:req, body}
      assert body["language"] == "sql"

      assert body["command"] ==
               "SELECT expand(vector.fuse(" <>
                 "(SELECT expand(vector.neighbors('Doc[embedding]', :vec0, :k0))), " <>
                 "(SELECT expand(vector.neighbors('Doc[embedding]', :vec1, :k1))), " <>
                 "{fusion:'RRF'}))"

      assert body["params"] == %{"vec0" => [1.0, 0.0], "k0" => 3, "vec1" => [0.0, 1.0], "k1" => 3}
    end

    test "defaults fusion to RRF and rejects a bad fusion strategy value-free" do
      Req.Test.stub(__MODULE__, fn c ->
        send(self(), {:cmd, Jason.decode!(Req.Test.raw_body(c))["command"]})
        Req.Test.json(c, %{"result" => []})
      end)

      assert {:ok, []} = Vector.fuse(conn(), [{"Doc", "embedding", [1.0], 2}])
      assert_received {:cmd, cmd}
      assert cmd =~ "{fusion:'RRF'}"

      assert_raise ArgumentError, ~r/fusion/, fn ->
        Vector.fuse(conn(), [{"Doc", "embedding", [1.0], 2}], fusion: :magic)
      end
    end

    test "rejects a bad identifier in any spec value-free" do
      assert {:error, :invalid_identifier} =
               Vector.fuse(conn(), [
                 {"Doc", "embedding", [1.0], 2},
                 {"Doc]", "embedding", [1.0], 2}
               ])
    end

    test "rejects non-list weights value-free (no value echoed)" do
      err =
        assert_raise ArgumentError, fn ->
          Vector.fuse(conn(), [{"Doc", "embedding", [1.0], 2}], weights: "SEKRIT")
        end

      assert err.message =~ "weights"
      refute err.message =~ "SEKRIT"
    end

    test "rejects a non-list, empty, or malformed neighbor_specs value-free" do
      # non-list specs must not leak the value through an uncontrolled Enumerable crash
      nonlist = assert_raise ArgumentError, fn -> Vector.fuse(conn(), "SEKRIT_SPECS") end
      assert nonlist.message =~ "neighbor_specs"
      refute nonlist.message =~ "SEKRIT_SPECS"

      # empty specs must reject rather than emit malformed `vector.fuse(, {...})`
      assert_raise ArgumentError, ~r/neighbor_specs/, fn -> Vector.fuse(conn(), []) end

      # a malformed spec tuple must raise a controlled value-free error, not FunctionClauseError
      bad =
        assert_raise ArgumentError, fn ->
          Vector.fuse(conn(), [{"Doc", "embedding", "SEKRIT_ELEM"}])
        end

      assert bad.message =~ "neighbor_spec"
      refute bad.message =~ "SEKRIT_ELEM"
    end

    test "composes weights and k fusion opts into the fusion object (params-only for caller vectors)" do
      Req.Test.stub(__MODULE__, fn c ->
        send(self(), {:cmd, Jason.decode!(Req.Test.raw_body(c))})
        Req.Test.json(c, %{"result" => []})
      end)

      assert {:ok, []} =
               Vector.fuse(conn(), [{"Doc", "embedding", [1.0, 0.0], 3}],
                 weights: [0.7, 0.3],
                 k: 10
               )

      assert_received {:cmd, body}

      assert body["command"] ==
               "SELECT expand(vector.fuse(" <>
                 "(SELECT expand(vector.neighbors('Doc[embedding]', :vec0, :k0))), " <>
                 "{fusion:'RRF', weights:[0.7, 0.3], k:10}))"

      assert body["params"] == %{"vec0" => [1.0, 0.0], "k0" => 3}
    end
  end
end
