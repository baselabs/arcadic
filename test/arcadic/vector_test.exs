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
      assert_raise ArgumentError, ~r/similarity/, fn ->
        Vector.create_dense_index(conn(), "Doc", "embedding", 3, similarity: :manhattan)
      end

      err =
        assert_raise ArgumentError, fn ->
          Vector.create_dense_index(conn(), "Doc", "embedding", 0)
        end

      assert err.message =~ "dimensions"
      refute err.message =~ "manhattan"
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
end
