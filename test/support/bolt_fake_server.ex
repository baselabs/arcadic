defmodule Arcadic.Test.BoltFakeServer do
  @moduledoc """
  A throwaway TCP listener that speaks just enough of the Bolt handshake to drive
  arcadic's connect failure paths without a real server. Owned by a spawned process,
  so the ACCEPTED socket and the LISTEN socket are NOT owned by the caller — only the
  arcadic-side client socket is, which is exactly what the fd-delta probe measures.
  """

  # scenario: :version_negotiation | :non_bolt | :stall
  # Returns {:ok, port} to point leak_safe_connect at (hostname: "127.0.0.1", port: port).
  def start(scenario) do
    {:ok, lsock} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(lsock)

    spawn_link(fn -> accept_loop(lsock, scenario) end)
    {:ok, port}
  end

  defp accept_loop(lsock, scenario) do
    {:ok, sock} = :gen_tcp.accept(lsock)
    # consume the 20-byte handshake (4 magic + 16 version bytes) before replying
    _ = :gen_tcp.recv(sock, 20, 1_000)
    reply(sock, scenario)
    accept_loop(lsock, scenario)
  end

  # path A: negotiate version 0.0 (no common version)
  defp reply(sock, :version_negotiation), do: :gen_tcp.send(sock, <<0, 0, 0, 0>>)

  # path B: a non-Bolt endpoint (an HTTP reply — the handshake read consumes only the
  # first 4 bytes, "HTTP", which fails the version match).
  defp reply(sock, :non_bolt),
    do: :gen_tcp.send(sock, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")

  # timeout: complete TCP + read handshake, then never reply
  defp reply(_sock, :stall), do: Process.sleep(:infinity)
end
