defmodule Arcadic.MigratorTest do
  @moduledoc """
  Unit proofs for the migrator's crash-recovery marker contract (the corrected-C3 design,
  .kimosabe/specs/migrator-crash-recovery.md): a migration attempt is bracketed by a durable
  `up_started`/`down_started` marker that is removed ONLY by successful finalization or explicit
  `resolve/3` — never by an error cleanup — so an interrupted migration can never silently re-run.
  Live durability (a marker surviving process death) is proven by the integration suite.
  """
  use ExUnit.Case, async: true
  alias Arcadic.{Conn, Migrator}

  defp conn,
    do:
      Conn.new("http://arcade.invalid", "mydb",
        auth: {"root", "x"},
        transport_options: [plug: {Req.Test, __MODULE__}]
      )

  defmodule V1 do
    @behaviour Arcadic.Migration
    @impl true
    def version, do: 1
    @impl true
    def up(conn) do
      Arcadic.command!(conn, "CREATE VERTEX TYPE Foo", %{}, language: "sql")
      :ok
    end

    @impl true
    def down(conn) do
      Arcadic.command!(conn, "DROP TYPE Foo IF EXISTS", %{}, language: "sql")
      :ok
    end
  end

  defmodule V2 do
    @behaviour Arcadic.Migration
    @impl true
    def version, do: 2
    @impl true
    def up(conn) do
      Arcadic.command!(conn, "CREATE VERTEX TYPE Bar", %{}, language: "sql")
      :ok
    end

    @impl true
    def down(conn) do
      Arcadic.command!(conn, "DROP TYPE Bar IF EXISTS", %{}, language: "sql")
      :ok
    end
  end

  defmodule Failing do
    @behaviour Arcadic.Migration
    @impl true
    def version, do: 3
    @impl true
    def up(_conn), do: {:error, :nope}
    @impl true
    def down(_conn), do: {:error, :nope}
  end

  defmodule Crashing do
    @behaviour Arcadic.Migration
    @impl true
    def version, do: 4
    @impl true
    def up(_conn), do: raise("boom mid-up")
    @impl true
    def down(_conn), do: raise("boom mid-down")
  end

  defmodule Registry do
    use Arcadic.MigrationRegistry
    migrations([V1, V2])
  end

  defmodule FailingRegistry do
    use Arcadic.MigrationRegistry
    migrations([Failing])
  end

  defmodule CrashingRegistry do
    use Arcadic.MigrationRegistry
    migrations([Crashing])
  end

  # The stub: record every command, answer by shape. `state` injects pre-existing tracking rows.
  defp stub(rows \\ []) do
    Req.Test.stub(__MODULE__, fn c ->
      decoded = Jason.decode!(Req.Test.raw_body(c))
      cmd = decoded["command"]
      send(self(), {:cmd, cmd, decoded["params"]})

      cond do
        cmd =~ "SELECT version" ->
          Req.Test.json(c, %{"result" => rows})

        cmd =~ "UPDATE _arcadic_migrations" ->
          Req.Test.json(c, %{"result" => [%{"count" => 1}]})

        cmd =~ "DELETE FROM _arcadic_migrations" ->
          Req.Test.json(c, %{"result" => [%{"count" => 1}]})

        cmd =~ "INSERT INTO _arcadic_migrations" ->
          Req.Test.json(c, %{"result" => [%{"version" => decoded["params"]["v"]}]})

        true ->
          Req.Test.json(c, %{"result" => []})
      end
    end)
  end

  describe "pending_migrations/2 (pure)" do
    test "filters applied and sorts by version ascending" do
      assert Migrator.pending_migrations([V2, V1], []) == [V1, V2]
      assert Migrator.pending_migrations([V1, V2], [1]) == [V2]
      assert Migrator.pending_migrations([V1, V2], [1, 2]) == []
    end
  end

  describe "migrate/2 happy path" do
    test "marks up_started before up, finalizes done after, records via bound param" do
      stub()

      assert {:ok, 2} = Migrator.migrate(conn(), Registry)

      assert_received {:cmd, "CREATE DOCUMENT TYPE _arcadic_migrations IF NOT EXISTS", _}

      assert_received {:cmd, "SELECT version, status FROM _arcadic_migrations ORDER BY version",
                       _}

      # V1: marker (version AND status both bound params) → DDL → done
      assert_received {:cmd,
                       "INSERT INTO _arcadic_migrations SET version = :v, status = :s, applied_at = sysdate()",
                       %{"v" => 1, "s" => "up_started"}}

      assert_received {:cmd, "CREATE VERTEX TYPE Foo", _}

      assert_received {:cmd, "UPDATE _arcadic_migrations SET status = :s WHERE version = :v",
                       %{"v" => 1, "s" => "done"}}

      # V2 runs only after V1 finalized
      assert_received {:cmd, _, %{"v" => 2, "s" => "up_started"}}
    end
  end

  describe "an interrupted migration REFUSES the next run (the crash window is loud)" do
    test "migrate refuses value-free when an up_started marker exists" do
      stub([%{"version" => 7, "status" => "up_started"}])

      assert {:error, %Arcadic.Error{reason: :interrupted_migration}} =
               Migrator.migrate(conn(), Registry)

      # Value-free (Rule 3): the version never rides the message; interrupted/1 is the reader.
      refute_received {:cmd, "INSERT INTO _arcadic_migrations" <> _, _}
    end

    test "rollback and status refuse too; interrupted/1 reports the stuck versions" do
      stub([%{"version" => 7, "status" => "down_started"}])

      assert {:error, %Arcadic.Error{reason: :interrupted_migration}} =
               Migrator.rollback(conn(), Registry)

      assert {:error, %Arcadic.Error{reason: :interrupted_migration}} =
               Migrator.status(conn(), Registry)

      assert {:ok, [7]} = Migrator.interrupted(conn())
    end

    test "an up error KEEPS the marker — no UPDATE and no DELETE cleanup" do
      stub()

      assert {:error, :nope} = Migrator.migrate(conn(), FailingRegistry)
      assert_received {:cmd, _, %{"v" => 3, "s" => "up_started"}}
      refute_received {:cmd, "UPDATE _arcadic_migrations" <> _, %{"v" => 3}}
      refute_received {:cmd, "DELETE FROM _arcadic_migrations" <> _, %{"v" => 3}}
    end

    test "a FAILED finalization (lost response after up) keeps the marker and returns the error" do
      # The stub's UPDATE branch answers a transport timeout (Req.Test.transport_error),
      # which the transport layer surfaces as %TransportError{reason: :timeout} — the
      # finalization's outcome is unknown, so the marker must survive.
      Req.Test.stub(__MODULE__, fn c ->
        decoded = Jason.decode!(Req.Test.raw_body(c))
        cmd = decoded["command"]
        send(self(), {:cmd, cmd, decoded["params"]})

        cond do
          cmd =~ "SELECT version" -> Req.Test.json(c, %{"result" => []})
          cmd =~ "UPDATE _arcadic_migrations" -> Req.Test.transport_error(c, :timeout)
          cmd =~ "INSERT INTO _arcadic_migrations" -> Req.Test.json(c, %{"result" => []})
          true -> Req.Test.json(c, %{"result" => []})
        end
      end)

      assert {:error, %Arcadic.TransportError{reason: :timeout}} =
               Migrator.migrate(conn(), Registry)

      # The marker from the completed V1 attempt SURVIVES the lost finalization.
      assert_received {:cmd, _, %{"v" => 1, "s" => "up_started"}}
      refute_received {:cmd, "DELETE FROM _arcadic_migrations" <> _, %{"v" => 1}}
    end

    test "an up RAISE keepS the marker and propagates" do
      stub()

      assert_raise RuntimeError, ~r/boom mid-up/, fn ->
        Migrator.migrate(conn(), CrashingRegistry)
      end

      assert_received {:cmd, _, %{"v" => 4, "s" => "up_started"}}
      refute_received {:cmd, "UPDATE _arcadic_migrations" <> _, %{"v" => 4}}
    end
  end

  describe "legacy rows (pre-marker schema) read as applied" do
    test "a status-less row counts as done across all entry points (no eager backfill write)" do
      stub([%{"version" => 1, "status" => nil}])

      assert {:ok, [{1, :up}, {2, :down}]} = Migrator.status(conn(), Registry)
      assert {:ok, []} = Migrator.interrupted(conn())

      assert {:ok, 1} = Migrator.migrate(conn(), Registry)
      assert_received {:cmd, _, %{"v" => 2, "s" => "up_started"}}
    end
  end

  describe "resolve/3 records the operator's established outcome" do
    test ":applied finalizes the marker as done (verified transition)" do
      stub([%{"version" => 7, "status" => "up_started"}])

      assert :ok = Migrator.resolve(conn(), 7, :applied)

      assert_received {:cmd, "UPDATE _arcadic_migrations SET status = :s WHERE version = :v",
                       %{"v" => 7, "s" => "done"}}
    end

    test ":not_applied deletes the row (verified transition)" do
      stub([%{"version" => 7, "status" => "down_started"}])

      assert :ok = Migrator.resolve(conn(), 7, :not_applied)
      assert_received {:cmd, "DELETE FROM _arcadic_migrations WHERE version = :v", %{"v" => 7}}
    end

    test "a non-interrupted version is rejected value-free" do
      stub([%{"version" => 1, "status" => "done"}])

      assert {:error, %Arcadic.Error{reason: :invalid_state}} =
               Migrator.resolve(conn(), 1, :applied)
    end

    test "a zero-row transition is a verified failure (never a silent no-op success)" do
      Req.Test.stub(__MODULE__, fn c ->
        cmd = Jason.decode!(Req.Test.raw_body(c))["command"]

        cond do
          cmd =~ "SELECT version" ->
            Req.Test.json(c, %{"result" => [%{"version" => 7, "status" => "up_started"}]})

          cmd =~ "UPDATE _arcadic_migrations" ->
            Req.Test.json(c, %{"result" => [%{"count" => 0}]})

          true ->
            Req.Test.json(c, %{"result" => []})
        end
      end)

      assert {:error, %Arcadic.Error{reason: :invalid_state}} =
               Migrator.resolve(conn(), 7, :applied)
    end
  end

  describe "session conns are rejected (autocommit is enforced, not assumed)" do
    test "every entry point rejects a session-scoped conn value-free" do
      tx = %{conn() | session_id: "AS-x"}

      assert_raise ArgumentError, ~r/session/, fn -> Migrator.migrate(tx, Registry) end
      assert_raise ArgumentError, ~r/session/, fn -> Migrator.rollback(tx, Registry) end
      assert_raise ArgumentError, ~r/session/, fn -> Migrator.status(tx, Registry) end
      assert_raise ArgumentError, ~r/session/, fn -> Migrator.interrupted(tx) end
      assert_raise ArgumentError, ~r/session/, fn -> Migrator.resolve(tx, 1, :applied) end
    end
  end

  describe "rollback/3 down lifecycle" do
    test "down TRANSITIONS the existing done row (never inserts a second one)" do
      stub([%{"version" => 1, "status" => "done"}])

      assert {:ok, 1} = Migrator.rollback(conn(), Registry, 1)

      assert_received {:cmd, "UPDATE _arcadic_migrations SET status = :s WHERE version = :v",
                       %{"v" => 1, "s" => "down_started"}}

      assert_received {:cmd, "DROP TYPE Foo IF EXISTS", _}
      assert_received {:cmd, "DELETE FROM _arcadic_migrations WHERE version = :v", %{"v" => 1}}
      refute_received {:cmd, "INSERT INTO _arcadic_migrations" <> _, _}
    end

    test "a down ERROR keeps the down_started row (no delete cleanup)" do
      stub([%{"version" => 3, "status" => "done"}])

      assert {:error, :nope} = Migrator.rollback(conn(), FailingRegistry, 1)

      assert_received {:cmd, "UPDATE _arcadic_migrations SET status = :s WHERE version = :v",
                       %{"v" => 3, "s" => "down_started"}}

      refute_received {:cmd, "DELETE FROM _arcadic_migrations" <> _, %{"v" => 3}}
    end

    test "an unverified marker transition (zero rows) refuses to run the down" do
      Req.Test.stub(__MODULE__, fn c ->
        cmd = Jason.decode!(Req.Test.raw_body(c))["command"]

        cond do
          cmd =~ "SELECT version" ->
            Req.Test.json(c, %{"result" => [%{"version" => 1, "status" => "done"}]})

          cmd =~ "UPDATE _arcadic_migrations" ->
            Req.Test.json(c, %{"result" => [%{"count" => 0}]})

          true ->
            Req.Test.json(c, %{"result" => []})
        end
      end)

      assert {:error, %Arcadic.Error{reason: :invalid_state}} =
               Migrator.rollback(conn(), Registry, 1)

      refute_received {:cmd, "DROP TYPE Foo IF EXISTS", _}
    end
  end

  defp collect_cmds(n) do
    for _ <- 1..n do
      receive do
        {:cmd, c, p} -> {:cmd, c, p}
      after
        0 -> :missing
      end
    end
  end

  describe "status/2" do
    test "reports up/down per version" do
      stub([%{"version" => 1, "status" => "done"}])

      assert {:ok, [{1, :up}, {2, :down}]} = Migrator.status(conn(), Registry)
    end
  end
end
