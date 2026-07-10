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

  test "set_server_setting/3 emits the backtick command and returns :ok" do
    Req.Test.stub(__MODULE__, fn c ->
      send(self(), {:cmd, Jason.decode!(Req.Test.raw_body(c))["command"]})
      Req.Test.json(c, %{"result" => "ok"})
    end)

    assert :ok = Server.set_server_setting(conn(), "arcadedb.serverMetrics", "true")
    assert_received {:cmd, "set server setting `arcadedb.serverMetrics` `true`"}
  end

  test "set_database_setting/3 targets conn.database" do
    Req.Test.stub(__MODULE__, fn c ->
      send(self(), {:cmd, Jason.decode!(Req.Test.raw_body(c))["command"]})
      Req.Test.json(c, %{"result" => "ok"})
    end)

    assert :ok = Server.set_database_setting(conn(), "arcadedb.flushOnly", "false")
    assert_received {:cmd, "set database setting db `arcadedb.flushOnly` `false`"}
  end

  test "setting key/value guards reject value-free (no wire call) — both setters, symmetric" do
    # value-free: a stub that flunks if ANY request reaches the wire
    Req.Test.stub(__MODULE__, fn c ->
      send(self(), :wire)
      Req.Test.json(c, %{"result" => "ok"})
    end)

    # backtick (breakout), backslash (escape), newline (second-statement), DEL (control) — REJECTED.
    # A plain space is ALLOWED (inert inside the backtick-quoted value; the live server accepts it) —
    # covered by the happy-path test above, NOT asserted here (it would reach the wire).
    for bad_val <- ["ev`il", "ev\\il", "a\nb", "a\x7Fb"] do
      assert {:error, :invalid_setting_value} = Server.set_server_setting(conn(), "k.ok", bad_val)
    end

    # Non-binary value → graceful {:error,_}, never a FunctionClauseError (locks the fallback clause).
    assert {:error, :invalid_setting_value} = Server.set_server_setting(conn(), "k.ok", 123)

    assert {:error, :invalid_setting_key} = Server.set_server_setting(conn(), "bad`key", "v")
    assert {:error, :invalid_setting_key} = Server.set_server_setting(conn(), "bad key", "v")

    # Parallel-constructor symmetry: set_database_setting/3 shares the guards — feed it a bad value
    # AND a bad key so a future drop of its `with` guard prefix ships red, not silent.
    assert {:error, :invalid_setting_value} = Server.set_database_setting(conn(), "k.ok", "ev`il")
    assert {:error, :invalid_setting_key} = Server.set_database_setting(conn(), "bad`key", "v")

    refute_received :wire
  end
end
