defmodule Arcadic.ResultTest do
  use ExUnit.Case, async: true
  alias Arcadic.Result

  test "strips @props (serializer noise) from scalar rows" do
    body = %{"user" => "root", "result" => [%{"c" => 1, "@props" => "c:3"}]}
    assert Result.normalize(body) == {:ok, [%{"c" => 1}]}
  end

  test "keeps record identity keys on vertex rows" do
    row = %{"@rid" => "#1:0", "@type" => "Probe", "@cat" => "v", "k" => "v2", "num" => 42}
    assert Result.normalize(%{"result" => [row]}) == {:ok, [row]}
  end

  test "keeps @in/@out on edge rows" do
    edge = %{
      "@rid" => "#7:0",
      "@type" => "KNOWS",
      "@cat" => "e",
      "@in" => "#4:1",
      "@out" => "#4:0",
      "since" => 2020
    }

    assert Result.normalize(%{"result" => [edge]}) == {:ok, [edge]}
  end

  test "returns an empty list for a no-result command" do
    assert Result.normalize(%{"result" => []}) == {:ok, []}
  end

  test "returns an empty list when result is absent" do
    assert Result.normalize(%{"user" => "root"}) == {:ok, []}
  end

  test "returns an empty list when result is present but not a list (out of contract)" do
    # A scalar `result` (e.g. an async-accept string) must not crash Enum.map.
    assert Result.normalize(%{"result" => "Command accepted for asynchronous execution"}) ==
             {:ok, []}
  end

  describe "normalize_plan/1" do
    test "extracts plan (string) + plan_tree (map) + rows, @props-stripped" do
      body = %{
        "user" => "root",
        "result" => [%{"n" => 1, "@props" => "n:3"}],
        "explain" => "+ FETCH FROM TYPE Person ()",
        "explainPlan" => %{"type" => "QueryExecutionPlan", "steps" => []}
      }

      assert {:ok,
              %{
                plan: "+ FETCH FROM TYPE Person ()",
                plan_tree: %{"type" => "QueryExecutionPlan", "steps" => []},
                rows: [%{"n" => 1}]
              }} =
               Result.normalize_plan(body)
    end

    test "defaults every key when the envelope omits it (EXPLAIN has empty result)" do
      assert {:ok, %{plan: "", plan_tree: %{}, rows: []}} =
               Result.normalize_plan(%{"user" => "root"})
    end

    test "carries a non-empty rows list for a Cypher PROFILE (executed rows)" do
      body = %{
        "result" => [%{"@rid" => "#1:0", "name" => "Ann"}],
        "explain" => "prof",
        "explainPlan" => %{"cost" => 1}
      }

      assert {:ok,
              %{
                rows: [%{"@rid" => "#1:0", "name" => "Ann"}],
                plan: "prof",
                plan_tree: %{"cost" => 1}
              }} =
               Result.normalize_plan(body)
    end
  end

  describe "normalize/1 use_explain guard" do
    test "a plan envelope in the rows path returns a value-free :use_explain error" do
      body = %{"result" => [], "explain" => "plan", "explainPlan" => %{"type" => "x"}}
      assert {:error, %Arcadic.Error{reason: :use_explain} = e} = Result.normalize(body)
      refute e.message =~ "plan"
      assert e.message =~ "explain/3"
    end

    test "a normal response is unaffected by the guard" do
      assert {:ok, [%{"n" => 1}]} = Result.normalize(%{"result" => [%{"n" => 1}]})
    end
  end
end
