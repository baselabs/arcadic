defmodule Arcadic.MigrationRegistryTest do
  use ExUnit.Case, async: true

  defmodule M1, do: def(version, do: 1)
  defmodule M2, do: def(version, do: 2)

  defmodule Registry do
    use Arcadic.MigrationRegistry
    migrations([M1, M2])
  end

  test "the use macro generates an ordered migrations/0" do
    assert Registry.migrations() == [
             Arcadic.MigrationRegistryTest.M1,
             Arcadic.MigrationRegistryTest.M2
           ]
  end

  test "the registry adopts the behaviour" do
    assert {:migrations, 0} in Arcadic.MigrationRegistry.behaviour_info(:callbacks)
  end
end
