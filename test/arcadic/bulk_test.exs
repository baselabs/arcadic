defmodule Arcadic.BulkTest do
  use ExUnit.Case, async: true
  alias Arcadic.{Bulk, Conn}

  defp conn,
    do:
      Conn.new("http://arcade.invalid", "mydb",
        auth: {"root", "x"},
        transport_options: [plug: {Req.Test, __MODULE__}]
      )

  defp stub_ok do
    Req.Test.stub(__MODULE__, fn c ->
      send(self(), {:body, Req.Test.raw_body(c)})
      Req.Test.json(c, %{"verticesCreated" => 2, "edgesCreated" => 0, "elapsedMs" => 3})
    end)
  end

  test "serializes records to NDJSON and returns atom-keyed counts" do
    stub_ok()

    assert {:ok, %{vertices_created: 2, edges_created: 0, elapsed_ms: 3}} =
             Bulk.ingest(conn(), [
               %{"@type" => "vertex", "@class" => "P", "id" => 1},
               %{"@type" => "vertex", "@class" => "P", "id" => 2}
             ])

    assert_received {:body, body}

    # Order-independent: decode each NDJSON line back to a map (Jason does not guarantee key order).
    lines = body |> IO.iodata_to_binary() |> String.split("\n", trim: true)
    assert length(lines) == 2

    assert Enum.map(lines, &Jason.decode!/1) == [
             %{"@type" => "vertex", "@class" => "P", "id" => 1},
             %{"@type" => "vertex", "@class" => "P", "id" => 2}
           ]
  end

  test "a non-map record is rejected value-free before any wire call" do
    err =
      assert_raise ArgumentError, fn ->
        Bulk.ingest(conn(), [%{"@type" => "vertex"}, "SEKRIT"])
      end

    refute err.message =~ "SEKRIT"
  end

  test "an unencodable record value yields {:error, :invalid_record} (never Jason.encode! leak)" do
    # An atom-keyed map with a non-UTF-8 binary value: Jason.encode/1 returns {:error, _}.
    bad = %{"@type" => "vertex", "v" => <<0xFF, 0xFE>>}
    assert {:error, :invalid_record} = Bulk.ingest(conn(), [bad])
  end

  test "id_property is Identifier-validated value-free" do
    err =
      assert_raise ArgumentError, fn ->
        Bulk.ingest(conn(), [%{"@type" => "vertex"}], id_property: "bad prop")
      end

    refute err.message =~ "bad prop"
  end

  test "an unknown opt is rejected value-free" do
    assert_raise ArgumentError, fn -> Bulk.ingest(conn(), [%{"@type" => "vertex"}], nope: 1) end
  end

  test "a non-list records arg is rejected value-free (record never echoed in blame)" do
    err =
      assert_raise ArgumentError, fn ->
        Bulk.ingest(conn(), %{"@type" => "vertex", "ssn" => "SEKRIT-record-999"})
      end

    refute err.message =~ "SEKRIT-record-999"
  end

  test "a Bolt conn (no batch_ingest/3) returns {:error, :not_supported}" do
    bolt = %{conn() | transport: Arcadic.Transport.Bolt}

    assert {:error, %Arcadic.Error{reason: :not_supported}} =
             Bulk.ingest(bolt, [%{"@type" => "vertex"}])
  end

  test "emits a value-free [:arcadic, :bulk, :stop] span with the created row_count" do
    stub_ok()
    ref = :telemetry_test.attach_event_handlers(self(), [[:arcadic, :bulk, :stop]])
    Bulk.ingest(conn(), [%{"@type" => "vertex", "@class" => "P", "id" => 1}])
    # row_count rides METADATA (pos 4), not measurements — Telemetry.span folds stop_meta into
    # :telemetry.span's metadata; stop measurements are fixed to %{duration, monotonic_time}.
    assert_received {[:arcadic, :bulk, :stop], ^ref, _measurements,
                     %{operation: :ingest, mode: :write, reason: :ok, row_count: 2}}

    :telemetry.detach(ref)
  end

  test "a non-map 2xx body is a typed {:error, :unexpected_response}, never a crash" do
    Req.Test.stub(__MODULE__, fn c -> Req.Test.json(c, []) end)

    assert {:error, :unexpected_response} =
             Bulk.ingest(conn(), [%{"@type" => "vertex", "@class" => "P", "id" => 1}])
  end

  test "an empty records list is a no-op zero-count success (no wire call)" do
    stub_ok()

    assert {:ok, %{vertices_created: 0, edges_created: 0, elapsed_ms: 0}} =
             Bulk.ingest(conn(), [])

    # stub_ok's send/2 fires only on a real request — an empty batch must not POST.
    refute_received {:body, _}
  end

  test "span row_count is the additive vertices + edges count" do
    Req.Test.stub(__MODULE__, fn c ->
      Req.Test.json(c, %{"verticesCreated" => 2, "edgesCreated" => 3, "elapsedMs" => 9})
    end)

    ref = :telemetry_test.attach_event_handlers(self(), [[:arcadic, :bulk, :stop]])
    Bulk.ingest(conn(), [%{"@type" => "edge", "@class" => "K", "@from" => 1, "@to" => 2}])
    # 2 + 3 = 5 — dropping `+ edgesCreated` from row_count goes red here.
    assert_received {[:arcadic, :bulk, :stop], ^ref, _m, %{reason: :ok, row_count: 5}}
    :telemetry.detach(ref)
  end

  test "ingest!/3 returns the bare counts map on success" do
    stub_ok()

    assert %{vertices_created: 2, edges_created: 0, elapsed_ms: 3} =
             Bulk.ingest!(conn(), [%{"@type" => "vertex", "@class" => "P", "id" => 1}])
  end

  test "ingest!/3 re-raises the underlying Arcadic.Error on an error result" do
    bolt = %{conn() | transport: Arcadic.Transport.Bolt}
    assert_raise Arcadic.Error, fn -> Bulk.ingest!(bolt, [%{"@type" => "vertex"}]) end
  end
end
