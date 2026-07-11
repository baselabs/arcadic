defmodule Arcadic.FailoverTest do
  use ExUnit.Case, async: false
  alias Arcadic.Conn

  # A plug stub that fails the FIRST host with a given transport reason (or a :not_leader body)
  # and serves JSON from the SECOND host. Keys on the request URL host.
  defp two_host_conn(fail_reason) do
    Req.Test.stub(__MODULE__, fn c ->
      cond do
        # :not_leader_body is ALSO an atom, so it must be excluded here or it would wrongly
        # route to Req.Test.transport_error/2 (which rejects it as an invalid transport reason).
        c.host == "h1.invalid" and is_atom(fail_reason) and fail_reason != :not_leader_body ->
          Req.Test.transport_error(c, fail_reason)

        c.host == "h1.invalid" and fail_reason == :not_leader_body ->
          c
          |> Plug.Conn.put_status(400)
          |> Req.Test.json(%{
            "error" => "Cannot execute command",
            "exception" => "com.arcadedb.network.binary.ServerIsNotTheLeaderException"
          })

        true ->
          Req.Test.json(c, %{"result" => [%{"host" => c.host}]})
      end
    end)

    Conn.new("http://h1.invalid", "db",
      auth: {"root", "x"},
      hosts: ["http://h2.invalid"],
      transport_options: [plug: {Req.Test, __MODULE__}]
    )
  end

  test "a READ fails over on ANY connection error (idempotent)" do
    conn = two_host_conn(:closed)

    assert {:ok, [%{"host" => "h2.invalid"}]} =
             Arcadic.query(conn, "SELECT 1", %{}, language: "sql")
  end

  test "a READ fails over on econnrefused too" do
    conn = two_host_conn(:econnrefused)

    assert {:ok, [%{"host" => "h2.invalid"}]} =
             Arcadic.query(conn, "SELECT 1", %{}, language: "sql")
  end

  test "a WRITE fails over on a PRE-SEND connect error (econnrefused)" do
    conn = two_host_conn(:econnrefused)
    assert {:ok, [%{"host" => "h2.invalid"}]} = Arcadic.command(conn, "CREATE (n)")
  end

  test "a WRITE does NOT fail over on an AMBIGUOUS post-send close (:closed) — surfaces the error" do
    conn = two_host_conn(:closed)

    assert {:error, %Arcadic.TransportError{reason: :closed}} =
             Arcadic.command(conn, "CREATE (n)")
  end

  test "a :not_leader response body fails over for a WRITE (rejection = safe)" do
    conn = two_host_conn(:not_leader_body)
    assert {:ok, [%{"host" => "h2.invalid"}]} = Arcadic.command(conn, "CREATE (n)")
  end

  test "single-host conn (no hosts) returns the error unchanged — no failover" do
    Req.Test.stub(__MODULE__.Single, fn c -> Req.Test.transport_error(c, :econnrefused) end)

    conn =
      Conn.new("http://h1.invalid", "db",
        auth: {"root", "x"},
        transport_options: [plug: {Req.Test, __MODULE__.Single}]
      )

    assert {:error, %Arcadic.TransportError{reason: :econnrefused}} =
             Arcadic.query(conn, "SELECT 1", %{}, language: "sql")
  end
end
