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

  test "set_server_setting/3 accepts a non-ASCII printable (UTF-8) value — inert in the backtick quoting" do
    Req.Test.stub(__MODULE__, fn c ->
      send(self(), {:cmd, Jason.decode!(Req.Test.raw_body(c))["command"]})
      Req.Test.json(c, %{"result" => "ok"})
    end)

    # Spec Decision 24 requires rejecting only a backtick + control chars — NOT all non-ASCII. A UTF-8
    # value (accent + non-Latin) is inert inside `k` `v` backtick quoting; blocking it was an
    # unauthorized capability narrowing (the guard was printable-ASCII-only).
    assert :ok = Server.set_server_setting(conn(), "arcadedb.serverName", "café-日本")
    assert_received {:cmd, "set server setting `arcadedb.serverName` `café-日本`"}
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

    # backtick (breakout), backslash (escape), newline (second-statement), DEL + a C1 control (U+0085
    # NEL) — REJECTED. A plain space is ALLOWED (inert inside the backtick-quoted value; the live
    # server accepts it) — covered by the happy-path test above, NOT asserted here (would reach wire).
    for bad_val <- ["ev`il", "ev\\il", "a\nb", "a\x7Fb", "a\u0085b"] do
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

  test "open/close/align_database validate the name value-free (no wire on bad name)" do
    Req.Test.stub(__MODULE__, fn c ->
      send(self(), :wire)
      Req.Test.json(c, %{"result" => "ok"})
    end)

    assert {:error, :invalid_identifier} = Server.open_database(conn(), "bad name")
    assert {:error, :invalid_identifier} = Server.close_database(conn(), "bad;name")
    assert {:error, :invalid_identifier} = Server.align_database(conn(), "1bad")
    refute_received :wire
  end

  test "open_database sends the command for a valid name" do
    Req.Test.stub(__MODULE__, fn c ->
      send(self(), {:cmd, Jason.decode!(Req.Test.raw_body(c))["command"]})
      Req.Test.json(c, %{"result" => "ok"})
    end)

    assert :ok = Server.open_database(conn(), "otherdb")
    assert_received {:cmd, "open database otherdb"}
  end

  test "check_database/2 runs CHECK DATABASE [FIX] and returns the integrity map" do
    Req.Test.stub(__MODULE__, fn c ->
      send(self(), {:cmd, Jason.decode!(Req.Test.raw_body(c))["command"]})

      Req.Test.json(c, %{
        "result" => [%{"operation" => "check database", "totalActiveRecords" => 0}]
      })
    end)

    assert {:ok, %{"operation" => "check database"}} = Server.check_database(conn())
    assert_received {:cmd, "CHECK DATABASE"}
    assert {:ok, _} = Server.check_database(conn(), fix: true)
    assert_received {:cmd, "CHECK DATABASE FIX"}
  end

  test "profiler/2 rejects an unknown action value-free; sends a valid one" do
    Req.Test.stub(__MODULE__, fn c ->
      send(self(), {:cmd, Jason.decode!(Req.Test.raw_body(c))["command"]})
      Req.Test.json(c, %{"recording" => true})
    end)

    assert_raise ArgumentError, ~r/profiler action/, fn -> Server.profiler(conn(), :on) end
    assert {:ok, _} = Server.profiler(conn(), :start)
    assert_received {:cmd, "profiler start"}
  end

  test "shutdown/1 sends the shutdown command (unit path; a real reset surfaces as {:error, :closed})" do
    Req.Test.stub(__MODULE__, fn c ->
      send(self(), {:cmd, Jason.decode!(Req.Test.raw_body(c))["command"]})
      Req.Test.json(c, %{"result" => "ok"})
    end)

    assert :ok = Server.shutdown(conn())
    assert_received {:cmd, "shutdown"}
  end

  test "close_database sends the command for a valid name" do
    Req.Test.stub(__MODULE__, fn c ->
      send(self(), {:cmd, Jason.decode!(Req.Test.raw_body(c))["command"]})
      Req.Test.json(c, %{"result" => "ok"})
    end)

    assert :ok = Server.close_database(conn(), "otherdb")
    assert_received {:cmd, "close database otherdb"}
  end

  test "align_database returns the raw command result on success (no to_ok)" do
    Req.Test.stub(__MODULE__, fn c ->
      send(self(), {:cmd, Jason.decode!(Req.Test.raw_body(c))["command"]})
      Req.Test.json(c, %{"result" => %{"realigned" => true}})
    end)

    assert {:ok, %{"result" => %{"realigned" => true}}} =
             Server.align_database(conn(), "otherdb")

    assert_received {:cmd, "align database otherdb"}
  end

  test "align_database surfaces a single-server server error as {:error, %Arcadic.Error{}}" do
    # Live contract (Task 13): a non-clustered node returns HTTP 500 with a
    # java.lang.UnsupportedOperationException FQN — matched by NO @exception_reasons
    # substring, so Error.from_response falls to reason: :server_error. align skips to_ok,
    # so the {:error, _} propagates raw.
    Req.Test.stub(__MODULE__, fn c ->
      c
      |> Plug.Conn.put_status(500)
      |> Req.Test.json(%{
        "error" => "Cannot align a non-clustered database",
        "exception" => "java.lang.UnsupportedOperationException"
      })
    end)

    assert {:error, %Arcadic.Error{reason: :server_error}} =
             Server.align_database(conn(), "otherdb")
  end

  test "check_database rejects an unknown opt key value-free (Opts.validate_keys!)" do
    # No stub registered: validate_keys! raises BEFORE any wire, so reaching the wire
    # would surface as a non-ArgumentError stub miss and fail this assert_raise.
    assert_raise ArgumentError, ~r/unknown option/, fn ->
      Server.check_database(conn(), bogus: 1)
    end
  end

  test "create_database emits a [:arcadic, :admin] span (operation :create_database) and keeps its :ok return" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:arcadic, :admin, :stop]])
    Req.Test.stub(__MODULE__, fn c -> Req.Test.json(c, %{"result" => "ok"}) end)
    assert :ok = Server.create_database(conn(), "newdb")
    assert_received {[:arcadic, :admin, :stop], ^ref, _m, %{operation: :create_database}}
    :telemetry.detach(ref)
  end

  test "drop_database emits a [:arcadic, :admin] span (operation :drop_database) and keeps its :ok return" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:arcadic, :admin, :stop]])
    Req.Test.stub(__MODULE__, fn c -> Req.Test.json(c, %{"result" => "ok"}) end)
    assert :ok = Server.drop_database(conn(), "newdb")
    assert_received {[:arcadic, :admin, :stop], ^ref, _m, %{operation: :drop_database}}
    :telemetry.detach(ref)
  end

  test "list_databases emits a [:arcadic, :admin] span (operation :list_databases) and keeps its {:ok, list} return" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:arcadic, :admin, :stop]])
    Req.Test.stub(__MODULE__, fn c -> Req.Test.json(c, %{"result" => ["db", "otherdb"]}) end)
    assert {:ok, ["db", "otherdb"]} = Server.list_databases(conn())

    assert_received {[:arcadic, :admin, :stop], ^ref, _m, %{operation: :list_databases} = meta}
    refute Map.has_key?(meta, :database)
    :telemetry.detach(ref)
  end

  test "database_exists? emits a [:arcadic, :admin] span (operation :database_exists?) and keeps its {:ok, bool} return" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:arcadic, :admin, :stop]])
    Req.Test.stub(__MODULE__, fn c -> Req.Test.json(c, %{"result" => ["db", "otherdb"]}) end)
    assert {:ok, true} = Server.database_exists?(conn(), "otherdb")
    assert_received {[:arcadic, :admin, :stop], ^ref, _m, %{operation: :database_exists?}}
    :telemetry.detach(ref)
  end

  test "ready? emits a [:arcadic, :admin] span (operation :ready?) and keeps its {:ok, bool} return" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:arcadic, :admin, :stop]])
    Req.Test.stub(__MODULE__, fn c -> Plug.Conn.send_resp(c, 204, "") end)
    assert {:ok, true} = Server.ready?(conn())
    assert_received {[:arcadic, :admin, :stop], ^ref, _m, %{operation: :ready?}}
    :telemetry.detach(ref)
  end
end
