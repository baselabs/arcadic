defmodule Arcadic.Transport.HTTPRequestTimeoutTest do
  @moduledoc """
  Proves the whole-response bound on a REAL socket: a server that trickles body
  bytes — each chunk arriving well within `receive_timeout` — is killed by
  `request_timeout`, and that a conn with no `request_timeout` lets the same
  trickle complete (Finch's default `:infinity` stands). This is exactly the
  hazard class `receive_timeout` cannot bound: it limits the wait PER CHUNK, so
  a slow-drip peer could otherwise hold a call open indefinitely.

  `async: false` — real-socket timing.
  """

  use ExUnit.Case, async: false

  alias Arcadic.{Conn, TransportError}

  # :gen_tcp server: accept one request, swallow whatever arrived, send response
  # headers, then drip the body one byte at a time. The content-type is
  # text/plain so the completed response decodes as a binary body (the 2xx
  # non-map degrade path), never through a JSON parser.
  defp start_trickler(parent, chunk_ms, total_bytes) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen)

    Task.start(fn ->
      {:ok, sock} = :gen_tcp.accept(listen, 10_000)
      :timer.sleep(50)
      # Swallow the request bytes that have arrived (headers + any body).
      {:ok, _} = :gen_tcp.recv(sock, 0, 200)

      :gen_tcp.send(
        sock,
        "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\ncontent-length: #{total_bytes}\r\n\r\n"
      )

      send(parent, :headers_sent)

      for i <- 1..total_bytes do
        :timer.sleep(chunk_ms)
        :gen_tcp.send(sock, ".")
        send(parent, {:byte, i})
      end

      :gen_tcp.close(sock)
      :gen_tcp.close(listen)
    end)

    port
  end

  defp conn(port, opts),
    do: Conn.new("http://127.0.0.1:#{port}", "db", [auth: {"root", "x"}] ++ opts)

  test "request_timeout kills a trickle that receive_timeout cannot bound" do
    # 20 bytes at 200 ms apart = a 4 s drip; every byte arrives far within the
    # 60 s receive timeout, so only the whole-response cap can stop it.
    port = start_trickler(self(), 200, 20)
    c = conn(port, timeout: 60_000, request_timeout: 400)

    t0 = System.monotonic_time(:millisecond)

    assert {:error, %TransportError{reason: :timeout}} =
             Arcadic.query(c, "SELECT 1", %{}, language: "sql")

    elapsed = System.monotonic_time(:millisecond) - t0
    assert elapsed < 2_000, "killed at ~400 ms expected, took #{elapsed} ms"
  end

  test "no request_timeout: the same (gentler) trickle completes — default unchanged" do
    port = start_trickler(self(), 30, 5)
    c = conn(port, timeout: 10_000)

    assert {:ok, []} = Arcadic.query(c, "SELECT 1", %{}, language: "sql")
  end
end
