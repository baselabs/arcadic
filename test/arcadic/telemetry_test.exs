defmodule Arcadic.TelemetryTest do
  use ExUnit.Case, async: true

  test "emits a span with allowlisted metadata" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:arcadic, :query, :stop]])

    result =
      Arcadic.Telemetry.span(:query, %{language: "cypher", mode: :read}, fn ->
        {{:ok, [%{"n" => 1}]}, %{http_status: 200, reason: :ok, row_count: 1}}
      end)

    assert result == {:ok, [%{"n" => 1}]}
    assert_received {[:arcadic, :query, :stop], ^ref, _measurements, meta}
    assert meta.language == "cypher"
    assert meta.http_status == 200
    assert meta.mode == :read
    assert meta.reason == :ok
    assert meta.row_count == 1
    :telemetry.detach(ref)
  end

  test "raises on an off-allowlist key returned in STOP metadata (locks merged validation)" do
    assert_raise ArgumentError, ~r/allowlist/, fn ->
      Arcadic.Telemetry.span(:query, %{language: "cypher"}, fn ->
        {{:ok, []}, %{database: "commercegraph"}}
      end)
    end
  end

  test "raises on an off-allowlist metadata key (no db name, no values)" do
    assert_raise ArgumentError, ~r/allowlist/, fn ->
      Arcadic.Telemetry.span(:query, %{database: "commercegraph"}, fn -> {{:ok, []}, %{}} end)
    end
  end

  test "database is NOT an allowed key (tenant-blind telemetry)" do
    refute :database in Arcadic.Telemetry.allowed_meta_keys()
  end
end
