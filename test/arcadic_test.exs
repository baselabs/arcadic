defmodule ArcadicTest do
  use ExUnit.Case, async: true

  test "module is defined and documented" do
    assert Code.ensure_loaded?(Arcadic)
    {:docs_v1, _, :elixir, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Arcadic)
    assert moduledoc =~ "HTTP Cypher command API"
  end
end
