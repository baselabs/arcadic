defmodule Arcadic.TransportTest do
  use ExUnit.Case, async: true

  test "declares the transport seam callbacks" do
    callbacks = Arcadic.Transport.behaviour_info(:callbacks)

    for cb <- [
          execute: 4,
          begin: 2,
          commit: 1,
          rollback: 1,
          server_command: 2,
          list_databases: 1,
          database_exists?: 2,
          ready?: 1
        ] do
      assert cb in callbacks, "missing callback #{inspect(cb)}"
    end
  end

  test "declares query_stream/3 as an optional callback" do
    assert {:query_stream, 3} in Arcadic.Transport.behaviour_info(:callbacks)
    assert {:query_stream, 3} in Arcadic.Transport.behaviour_info(:optional_callbacks)
  end
end
