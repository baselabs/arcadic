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
end
