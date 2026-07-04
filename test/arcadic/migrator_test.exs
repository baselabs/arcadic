defmodule Arcadic.MigratorTest do
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
    def up(conn),
      do:
        (
          Arcadic.command!(conn, "CREATE VERTEX TYPE Foo", %{}, language: "sql")
          :ok
        )

    @impl true
    def down(conn),
      do:
        (
          Arcadic.command!(conn, "DROP TYPE Foo IF EXISTS", %{}, language: "sql")
          :ok
        )
  end

  defmodule Registry do
    use Arcadic.MigrationRegistry
    migrations([V1])
  end

  test "pending_migrations/2 filters applied and sorts by version (pure)" do
    a = %{version: fn -> 1 end}
    # use real modules for version:
    assert Migrator.pending_migrations([V1], []) == [V1]
    assert Migrator.pending_migrations([V1], [1]) == []
    _ = a
  end

  test "migrate/2 ensures the type, runs pending up, and records the version" do
    Req.Test.stub(__MODULE__, fn c ->
      decoded = Jason.decode!(Req.Test.raw_body(c))
      cmd = decoded["command"]
      send(self(), {:cmd, cmd, decoded["params"]})

      cond do
        cmd =~ "SELECT version" ->
          Req.Test.json(c, %{"result" => []})

        cmd =~ "INSERT INTO _arcadic_migrations" ->
          Req.Test.json(c, %{"result" => [%{"version" => 1}]})

        true ->
          Req.Test.json(c, %{"result" => []})
      end
    end)

    assert {:ok, 1} = Migrator.migrate(conn(), Registry)
    assert_received {:cmd, "CREATE DOCUMENT TYPE _arcadic_migrations IF NOT EXISTS", _}
    assert_received {:cmd, "SELECT version FROM _arcadic_migrations ORDER BY version", _}
    assert_received {:cmd, "CREATE VERTEX TYPE Foo", _}

    # The version rides a bound param (:v), never interpolated into the statement
    # (params-only, Rule 1). The INSERT statement has no literal "1"; the value is in params.
    assert_received {:cmd,
                     "INSERT INTO _arcadic_migrations SET version = :v, applied_at = sysdate()",
                     %{"v" => 1}}
  end

  test "status/2 reports up/down per version" do
    Req.Test.stub(__MODULE__, fn c ->
      cmd = Jason.decode!(Req.Test.raw_body(c))["command"]

      if cmd =~ "SELECT version",
        do: Req.Test.json(c, %{"result" => [%{"version" => 1}]}),
        else: Req.Test.json(c, %{"result" => []})
    end)

    assert {:ok, [{1, :up}]} = Migrator.status(conn(), Registry)
  end
end
