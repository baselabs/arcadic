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

  test "explain/3 is an optional callback" do
    assert {:explain, 3} in Arcadic.Transport.behaviour_info(:optional_callbacks)
  end

  test "execute_with_index/4 is an optional callback" do
    assert {:execute_with_index, 4} in Arcadic.Transport.behaviour_info(:optional_callbacks)
  end

  test "ts_* time-series callbacks are declared optional" do
    optional = Arcadic.Transport.behaviour_info(:optional_callbacks)
    callbacks = Arcadic.Transport.behaviour_info(:callbacks)

    for cb <- [{:ts_write, 3}, {:ts_query, 3}, {:ts_latest, 3}, {:ts_prom_get, 4}] do
      assert cb in callbacks
      assert cb in optional
    end
  end
end
