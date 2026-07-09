defmodule Arcadic.Transport.BoltExplainTest do
  use ExUnit.Case, async: true

  @moduletag :bolt

  test "Bolt transport implements the explain/3 optional callback" do
    # function_exported? is vacuously false unless the target module is loaded (S6 T1 lesson).
    assert Code.ensure_loaded?(Arcadic.Transport.Bolt)
    assert function_exported?(Arcadic.Transport.Bolt, :explain, 3)
  end

  test "moduledoc shows the setup/1 transport_options shape, not the streaming-broken [bolt: …]-only form" do
    {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(Arcadic.Transport.Bolt)
    assert doc =~ "setup/1"
    refute doc =~ "transport_options: [bolt: conn_ref]"
  end

  describe "build_plan/1 (Boltx.Response → plan map, drift-guarded)" do
    test "extracts string-representation when args is a well-formed map" do
      resp = %Boltx.Response{
        plan: %{"args" => %{"string-representation" => "OpenCypher X"}},
        results: []
      }

      assert %{plan: "OpenCypher X", rows: []} = Arcadic.Transport.Bolt.build_plan(resp)
    end

    test "defaults plan to \"\" WITHOUT raising when nested args is a non-map (server/driver drift)" do
      # get_in(summary, ["args", ...]) would RAISE on a list/string/scalar args; the nested is_map
      # guard degrades to plan: "" instead, and plan_tree still carries the raw summary verbatim.
      for bad <- [%{"args" => [1, 2, 3]}, %{"args" => "str"}, %{"args" => 5}] do
        resp = %Boltx.Response{plan: bad, results: []}
        assert %{plan: "", plan_tree: ^bad, rows: []} = Arcadic.Transport.Bolt.build_plan(resp)
      end
    end

    test "defaults summary to %{} when neither plan nor profile is a map" do
      resp = %Boltx.Response{plan: nil, profile: nil, results: [%{"n" => 1}]}

      assert %{plan: "", plan_tree: %{}, rows: [%{"n" => 1}]} =
               Arcadic.Transport.Bolt.build_plan(resp)
    end
  end
end
