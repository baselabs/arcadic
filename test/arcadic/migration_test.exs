defmodule Arcadic.MigrationTest do
  use ExUnit.Case, async: true

  defmodule Sample do
    @behaviour Arcadic.Migration
    @impl true
    def version, do: 20_260_704_000_001
    @impl true
    def up(_conn), do: :ok
    @impl true
    def down(_conn), do: :ok
  end

  test "declares version/0, up/1, down/1" do
    cbs = Arcadic.Migration.behaviour_info(:callbacks)
    assert {:version, 0} in cbs
    assert {:up, 1} in cbs
    assert {:down, 1} in cbs
  end

  test "a module can implement it" do
    assert Sample.version() == 20_260_704_000_001
    assert Sample.up(nil) == :ok
    assert Sample.down(nil) == :ok
  end
end
