defmodule Arcadic.ParamsOnlyTest do
  # Enforcement gate for AGENTS.md Critical Rule 1 (params-only) — spec §14 promises
  # verbatim: "a param value never appears in the request statement string."
  #
  # This goes RED if any facade/transport path ever interpolates a bound VALUE into the
  # statement instead of leaving it in `params` (the arcadex `command <> value` defect
  # class). @secret is a distinct sentinel that can only appear in the statement string
  # if a code path put it there — so the refute is non-vacuous.
  use ExUnit.Case, async: true
  alias Arcadic.Conn

  @secret "S3CR3T-pii-value-must-never-appear-in-a-statement"

  defp conn,
    do:
      Conn.new("http://arcade.invalid", "mydb",
        auth: {"root", "x"},
        transport_options: [plug: {Req.Test, __MODULE__}]
      )

  defp capture_body do
    Req.Test.stub(__MODULE__, fn c ->
      send(self(), {:body, Jason.decode!(Req.Test.raw_body(c))})
      Req.Test.json(c, %{"result" => []})
    end)
  end

  test "query/4: the param value stays in params and never enters the statement" do
    capture_body()
    Arcadic.query(conn(), "MATCH (u:User {token: $t}) RETURN u", %{"t" => @secret})
    assert_received {:body, body}
    assert body["command"] == "MATCH (u:User {token: $t}) RETURN u"
    refute body["command"] =~ @secret
    assert body["params"] == %{"t" => @secret}
  end

  test "command/4: the param value stays in params and never enters the statement" do
    capture_body()
    Arcadic.command(conn(), "CREATE (u:User {token: $t}) RETURN u", %{"t" => @secret})
    assert_received {:body, body}
    refute body["command"] =~ @secret
    assert body["params"]["t"] == @secret
  end

  test "command_async/4: the param value stays in params and never enters the statement" do
    capture_body()
    Arcadic.command_async(conn(), "CREATE (u:Log {token: $t})", %{"t" => @secret})
    assert_received {:body, body}
    refute body["command"] =~ @secret
    assert body["params"]["t"] == @secret
  end
end
