defmodule Arcadic.ExplainTest do
  use ExUnit.Case, async: true
  alias Arcadic.Conn

  defp conn,
    do:
      Conn.new("http://arcade.invalid", "mydb",
        auth: {"root", "x"},
        transport_options: [plug: {Req.Test, __MODULE__}]
      )

  defp stub_plan do
    Req.Test.stub(__MODULE__, fn c ->
      raw = Req.Test.raw_body(c)
      send(self(), {:stmt, Jason.decode!(raw)["command"]})
      Req.Test.json(c, %{"result" => [], "explain" => "PLAN", "explainPlan" => %{"type" => "P"}})
    end)
  end

  # A transport implementing ONLY the required `execute/4` — no optional `explain/3`. Hoisted to
  # module level (not defined inside a test body) so both the tuple test and the bang test reference
  # the same module and nothing depends on cross-test definition order.
  defmodule NoExplain do
    @behaviour Arcadic.Transport
    @impl true
    def execute(_, _, _, _), do: {:ok, []}
  end

  test "explain/3 prepends EXPLAIN and returns the plan map" do
    stub_plan()

    assert {:ok, %{plan: "PLAN", plan_tree: %{"type" => "P"}, rows: []}} =
             Arcadic.explain(conn(), "SELECT FROM Person", %{}, language: "sql")

    assert_received {:stmt, "EXPLAIN SELECT FROM Person"}
  end

  test "profile/3 prepends PROFILE" do
    stub_plan()
    assert {:ok, %{plan: "PLAN"}} = Arcadic.profile(conn(), "MATCH (n) RETURN n")
    assert_received {:stmt, "PROFILE MATCH (n) RETURN n"}
  end

  test "explain!/3 returns the plan map or raises" do
    stub_plan()
    assert %{plan: "PLAN"} = Arcadic.explain!(conn(), "SELECT FROM Person", %{}, language: "sql")
  end

  test "explain/profile reject retries/limit/serializer opts value-free" do
    for opt <- [[retries: 3], [limit: 5], [serializer: :x]] do
      assert_raise ArgumentError, ~r/unknown option/, fn ->
        Arcadic.explain(conn(), "SELECT 1", %{}, opt)
      end

      assert_raise ArgumentError, ~r/unknown option/, fn ->
        Arcadic.profile(conn(), "SELECT 1", %{}, opt)
      end
    end
  end

  test "explain span fires [:arcadic, :explain, :stop] with mode + row_count" do
    stub_plan()

    :telemetry.attach(
      "t-explain",
      [:arcadic, :explain, :stop],
      fn _e, m, meta, _ -> send(self(), {:tel, m, meta}) end,
      nil
    )

    Arcadic.explain(conn(), "SELECT 1", %{}, language: "sql")
    assert_received {:tel, %{duration: _}, %{mode: :read, row_count: 0, reason: :ok}}
    :telemetry.detach("t-explain")
  end

  test "profile span carries mode: :write and in_transaction?: false (write-path meta)" do
    stub_plan()

    :telemetry.attach(
      "t-profile",
      [:arcadic, :explain, :stop],
      fn _e, _m, meta, _ -> send(self(), {:tel, meta}) end,
      nil
    )

    Arcadic.profile(conn(), "MATCH (n) RETURN n")
    assert_received {:tel, %{mode: :write, in_transaction?: false, reason: :ok}}
    :telemetry.detach("t-profile")
  end

  test "a transport without explain/3 returns :not_supported" do
    c = Conn.new("http://x.invalid", "db", auth: {"r", "p"}, transport: NoExplain)

    assert {:error, %Arcadic.Error{reason: :not_supported}} =
             Arcadic.explain(c, "SELECT 1", %{}, language: "sql")
  end

  test "explain!/profile! raise the surfaced :not_supported hint (bang path + message/1 fold end-to-end)" do
    c = Conn.new("http://x.invalid", "db", auth: {"r", "p"}, transport: NoExplain)

    assert_raise Arcadic.Error, ~r/does not support explain\/profile/, fn ->
      Arcadic.explain!(c, "SELECT 1", %{}, language: "sql")
    end

    assert_raise Arcadic.Error, ~r/does not support explain\/profile/, fn ->
      Arcadic.profile!(c, "SELECT 1", %{}, language: "sql")
    end
  end

  test "query/4 on an EXPLAIN statement surfaces :use_explain (response-layer guard, end to end)" do
    Req.Test.stub(__MODULE__, fn c ->
      Req.Test.json(c, %{"result" => [], "explainPlan" => %{"type" => "P"}})
    end)

    assert {:error, %Arcadic.Error{reason: :use_explain}} =
             Arcadic.query(conn(), "EXPLAIN SELECT FROM Person", %{}, language: "sql")
  end
end
