defmodule WsEchoServerTest do
  @moduledoc """
  Proves the `WsEchoServer` Bandit/WebSock harness end-to-end against a REAL
  `Mint.WebSocket` client: the server records inbound frames to its controller,
  acks them, delivers server-initiated pushes, drops connections on demand, and
  rejects the next handshake when armed. This is the substrate the `Changes`
  proof suite (Task 8) runs against.
  """
  use ExUnit.Case, async: false

  # The controller pid (self()) also receives the Mint client's raw `:tcp`
  # messages, so every frame pump selectively matches only transport tags and
  # leaves any `{:ws_echo, ...}` record in the mailbox for `assert_receive`.

  test "records the inbound frame, acks it, and delivers a server push" do
    {:ok, port} = WsEchoServer.start(self())

    {conn, websocket, ref} = connect_ws(port)

    {:ok, websocket, data} =
      Mint.WebSocket.encode(websocket, {:text, ~s({"action":"subscribe","database":"d"})})

    {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)

    # The server recorded the inbound frame to its controller (this test pid).
    assert_receive {:ws_echo, "subscribe", %{"database" => "d"}}

    # The client decodes the ack the handler pushed back.
    {conn, websocket, ack} = recv_text(conn, websocket, ref)
    assert Jason.decode!(ack)["result"] == "ok"

    # A server-initiated push arrives as a decodable text frame.
    :ok = WsEchoServer.push(port, "create", %{"@rid" => "#1:0"})
    {_conn, _websocket, pushed} = recv_text(conn, websocket, ref)
    decoded = Jason.decode!(pushed)
    assert decoded["changeType"] == "create"
    assert decoded["record"] == %{"@rid" => "#1:0"}
  end

  test "push/3 awaits handler registration when called right after the upgrade" do
    {:ok, port} = WsEchoServer.start(self())

    # No inbound round-trip first: push immediately after the 101 upgrade, while
    # Bandit may still be running Handler.init/1. This exercises await_handler!
    # racing self-registration (the hazard for Task 8's push-centric flows).
    {conn, websocket, ref} = connect_ws(port)
    :ok = WsEchoServer.push(port, "create", %{"@rid" => "#9:9"})

    {_conn, _websocket, pushed} = recv_text(conn, websocket, ref)
    assert Jason.decode!(pushed)["record"] == %{"@rid" => "#9:9"}
  end

  test "push/3 to a started-but-unconnected port fails closed with a clear error" do
    {:ok, port} = WsEchoServer.start(self())

    # No client ever connects, so no handler self-registers: push must raise a
    # descriptive ArgumentError, never crash on send(nil, ...).
    assert_raise ArgumentError, ~r/no handler registered/, fn ->
      WsEchoServer.push(port, "create", %{"@rid" => "#1:0"})
    end
  end

  test "drop/1 stops the live connection" do
    {:ok, port} = WsEchoServer.start(self())

    {conn, websocket, ref} = connect_ws(port)

    # Round-trip one frame to prove the handler is live and self-registered.
    {:ok, websocket, data} =
      Mint.WebSocket.encode(websocket, {:text, ~s({"action":"ping"})})

    {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)
    {conn, websocket, _ack} = recv_text(conn, websocket, ref)

    :ok = WsEchoServer.drop(port)
    assert closed?(conn, websocket, ref)
  end

  test "reject_next_handshake/1 fails only the next upgrade, then recovers" do
    {:ok, port} = WsEchoServer.start(self())
    :ok = WsEchoServer.reject_next_handshake(port)

    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port)
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/ws", [])
    {_conn, status, _headers} = await_upgrade(conn, ref)
    assert status == 401

    # The flag is one-shot: the following handshake succeeds.
    {:ok, conn2} = Mint.HTTP.connect(:http, "127.0.0.1", port)
    {:ok, conn2, ref2} = Mint.WebSocket.upgrade(:ws, conn2, "/ws", [])
    {_conn2, status2, _headers2} = await_upgrade(conn2, ref2)
    assert status2 == 101
  end

  # --- client helpers ---------------------------------------------------------

  defp connect_ws(port) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port)
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/ws", [])
    {conn, status, resp_headers} = await_upgrade(conn, ref)
    assert status == 101
    {:ok, conn, websocket} = Mint.WebSocket.new(conn, ref, status, resp_headers)
    {conn, websocket, ref}
  end

  defp await_upgrade(conn, ref, status \\ nil, headers \\ nil) do
    case Mint.WebSocket.stream(conn, next_tcp_message()) do
      {:ok, conn, responses} ->
        {status, headers, done?} =
          Enum.reduce(responses, {status, headers, false}, fn
            {:status, ^ref, s}, {_s, h, d} -> {s, h, d}
            {:headers, ^ref, hs}, {s, _h, d} -> {s, hs, d}
            {:done, ^ref}, {s, h, _d} -> {s, h, true}
            _other, acc -> acc
          end)

        if done?, do: {conn, status, headers}, else: await_upgrade(conn, ref, status, headers)

      {:error, _conn, reason, _responses} ->
        flunk("upgrade stream error: #{inspect(reason)}")
    end
  end

  defp recv_text(conn, websocket, ref) do
    {conn, responses} = pump(conn)
    next_text(conn, websocket, ref, collect_data(responses, ref))
  end

  defp next_text(conn, websocket, ref, <<>>), do: recv_text(conn, websocket, ref)

  defp next_text(conn, websocket, ref, data) do
    {:ok, websocket, frames} = Mint.WebSocket.decode(websocket, data)

    case for({:text, t} <- frames, do: t) do
      [text | _] -> {conn, websocket, text}
      [] -> recv_text(conn, websocket, ref)
    end
  end

  defp closed?(conn, websocket, ref) do
    case next_tcp_message() do
      {:tcp_closed, _socket} -> true
      message -> closed_after_stream?(conn, websocket, ref, message)
    end
  end

  defp closed_after_stream?(conn, websocket, ref, message) do
    # A transport error after a drop counts as closed.
    with {:ok, conn, responses} <- Mint.WebSocket.stream(conn, message),
         {:ok, websocket, frames} <-
           Mint.WebSocket.decode(websocket, collect_data(responses, ref)) do
      close_frame?(frames) or closed?(conn, websocket, ref)
    else
      _transport_error -> true
    end
  end

  defp close_frame?(frames), do: Enum.any?(frames, &match?({:close, _code, _reason}, &1))

  defp pump(conn) do
    case Mint.WebSocket.stream(conn, next_tcp_message()) do
      {:ok, conn, responses} -> {conn, responses}
      {:error, _conn, reason, _responses} -> flunk("recv stream error: #{inspect(reason)}")
    end
  end

  defp collect_data(responses, ref), do: for({:data, ^ref, d} <- responses, into: <<>>, do: d)

  # Selectively receive only transport messages so a co-mingled `{:ws_echo, ...}`
  # controller record is never consumed here.
  defp next_tcp_message do
    receive do
      {:tcp, _socket, _data} = message -> message
      {:tcp_closed, _socket} = message -> message
      {:tcp_error, _socket, _reason} = message -> message
    after
      2_000 -> flunk("timed out waiting for a transport message")
    end
  end
end
