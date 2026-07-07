defmodule Arcadic.AsyncTest do
  use ExUnit.Case, async: true
  alias Arcadic.Conn

  # A transport that deliberately omits the OPTIONAL execute_async/3 callback.
  defmodule NoAsyncTransport do
    @moduledoc false
    def execute(_conn, _mode, _request, _opts), do: {:ok, []}
  end

  defp conn,
    do:
      Conn.new("http://arcade.invalid", "mydb",
        auth: {"root", "x"},
        transport_options: [plug: {Req.Test, __MODULE__}]
      )

  test "command_async sends awaitResponse:false and returns :ok on HTTP 202" do
    Req.Test.stub(__MODULE__, fn c ->
      body = Jason.decode!(Req.Test.raw_body(c))
      send(self(), {:body, body})

      c
      |> Plug.Conn.put_status(202)
      |> Req.Test.json(%{"result" => "Command accepted for asynchronous execution"})
    end)

    assert :ok = Arcadic.command_async(conn(), "CREATE (n:Log {e:$e})", %{"e" => "x"})
    assert_received {:body, body}
    assert body["awaitResponse"] == false
    assert body["command"] == "CREATE (n:Log {e:$e})"
  end

  test "returns {:error, TransportError} on transport failure" do
    Req.Test.stub(__MODULE__, fn c -> Req.Test.transport_error(c, :econnrefused) end)

    assert {:error, %Arcadic.TransportError{reason: :econnrefused}} =
             Arcadic.command_async(conn(), "CREATE (n)")
  end

  test "returns {:error, Error} when the server rejects the async write (error body, not just transport failure)" do
    Req.Test.stub(__MODULE__, fn c ->
      c
      |> Plug.Conn.put_status(500)
      |> Req.Test.json(%{
        "error" => "boom",
        "exception" => "com.arcadedb.exception.CommandParsingException"
      })
    end)

    assert {:error, %Arcadic.Error{reason: :parse_error, http_status: 500}} =
             Arcadic.command_async(conn(), "MATCHX")
  end

  test "emits a command span flagged async?" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:arcadic, :command, :stop]])

    Req.Test.stub(__MODULE__, fn c ->
      c |> Plug.Conn.put_status(202) |> Req.Test.json(%{"result" => "ok"})
    end)

    Arcadic.command_async(conn(), "CREATE (n)")
    # `async: true` + a GLOBAL telemetry event means this handler also fires for
    # `:command:stop` events emitted by CONCURRENT tests (sync `command`, tx
    # `command!`) whose meta lacks `async?`. Pin `async?: true` in the pattern so the
    # selective receive matches THIS test's own async span, never a cross-talk event.
    assert_received {[:arcadic, :command, :stop], ^ref, _m, %{async?: true}}
    :telemetry.detach(ref)
  end

  test "command_async returns a typed :not_supported error on a transport without execute_async/3" do
    c =
      Conn.new("http://arcade.invalid", "mydb", auth: {"root", "x"}, transport: NoAsyncTransport)

    assert {:error, %Arcadic.Error{reason: :not_supported}} =
             Arcadic.command_async(c, "CREATE (n)")
  end

  test "rejects non-map params value-free — never echoes the offending value (Rule 3)" do
    # command_async bypasses run/5 (builds its own request) → guard it at the facade too, else
    # build_body's `map_size/1` raises a BadMapError echoing the caller value.
    err =
      assert_raise ArgumentError, fn ->
        Arcadic.command_async(conn(), "CREATE (n)", [{"api_token", "SENTINEL_SECRET_9f3a"}])
      end

    assert err.message =~ "params"
    refute err.message =~ "SENTINEL"
  end
end
