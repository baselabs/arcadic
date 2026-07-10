defmodule ArcadicTest do
  use ExUnit.Case, async: true

  test "module is defined and documented" do
    assert Code.ensure_loaded?(Arcadic)
    {:docs_v1, _, :elixir, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Arcadic)
    assert moduledoc =~ "HTTP Cypher command API"
  end

  defp conn,
    do:
      Arcadic.connect("http://a.invalid", "db",
        auth: {"root", "x"},
        transport_options: [plug: {Req.Test, __MODULE__}]
      )

  test "command/4 forwards :auto_commit (incl. false) as the autoCommit body param" do
    conn = conn()

    Req.Test.stub(__MODULE__, fn c ->
      send(self(), {:body, Jason.decode!(Req.Test.raw_body(c))})
      Req.Test.json(c, %{"result" => []})
    end)

    Arcadic.command(conn, "CREATE (n)", %{}, auto_commit: false)
    assert_received {:body, %{"autoCommit" => false}}

    Arcadic.command(conn, "CREATE (n)", %{}, auto_commit: true)
    assert_received {:body, %{"autoCommit" => true}}

    Arcadic.command(conn, "CREATE (n)", %{})
    assert_received {:body, body}
    refute Map.has_key?(body, "autoCommit")
  end

  test "query/4 rejects :auto_commit value-free (not in @query_opts)" do
    assert_raise ArgumentError, fn ->
      Arcadic.query(conn(), "MATCH (n) RETURN n", %{}, auto_commit: true)
    end
  end
end
