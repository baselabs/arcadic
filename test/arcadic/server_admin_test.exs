defmodule Arcadic.ServerAdminTest do
  use ExUnit.Case, async: true
  alias Arcadic.{Conn, Server}

  defp conn,
    do:
      Conn.new("http://a.invalid", "db",
        auth: {"root", "x"},
        transport_options: [plug: {Req.Test, __MODULE__}]
      )

  test "info/2 builds ?mode=<mode> and returns the map; metrics/1 extracts the metrics submap" do
    Req.Test.stub(__MODULE__, fn c ->
      send(self(), {:path, c.request_path, c.query_string})

      Req.Test.json(c, %{"version" => "26.8.1", "metrics" => %{"profiler" => %{"pagesRead" => 1}}})
    end)

    assert {:ok, %{"version" => "26.8.1"}} = Server.info(conn(), mode: :default)
    assert_received {:path, "/api/v1/server", "mode=default"}
    assert {:ok, %{"profiler" => %{"pagesRead" => 1}}} = Server.metrics(conn())
  end

  test "info/2 rejects an unknown mode value-free" do
    assert_raise ArgumentError, ~r/mode must be/, fn -> Server.info(conn(), mode: :bogus) end
  end

  test "health?/1 maps 204 → true" do
    Req.Test.stub(__MODULE__, fn c -> Plug.Conn.send_resp(c, 204, "") end)
    assert {:ok, true} = Server.health?(conn())
  end

  test "events/1 returns the events map" do
    Req.Test.stub(__MODULE__, fn c ->
      Req.Test.json(c, %{"result" => %{"events" => [], "files" => []}})
    end)

    assert {:ok, %{"events" => [], "files" => []}} = Server.events(conn())
  end

  test "admin ops emit a value-free [:arcadic, :admin] span (operation only)" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:arcadic, :admin, :stop]])
    Req.Test.stub(__MODULE__, fn c -> Req.Test.json(c, %{"result" => %{"events" => []}}) end)
    Server.events(conn())
    assert_received {[:arcadic, :admin, :stop], ^ref, _measure, %{operation: :events} = meta}
    refute Map.has_key?(meta, :database)
    :telemetry.detach(ref)
  end

  test "an admin read whose callback Bolt lacks (server_get) returns :not_supported via the guard" do
    # NB: Bolt DOES implement server_command/2 (returns its own :not_supported), so use an op routed
    # through server_get (which Bolt does NOT export) to exercise Admin.guard's absent-branch.
    c = %{conn() | transport: Arcadic.Transport.Bolt}
    assert {:error, %Arcadic.Error{reason: :not_supported}} = Server.info(c, mode: :basic)
  end
end
