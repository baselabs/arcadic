defmodule Arcadic.Test.BoltFakeServer do
  @moduledoc """
  Unit-only byte peer for hostile replies, truncated packets, stalls, and socket
  cleanup paths a live ArcadeDB cannot intentionally produce. Integration tests
  always use the real server. The peer owns and closes both sockets and is stopped
  by the test's on_exit callback even when a scenario deliberately stalls.
  """

  def start(scenario) do
    start_script(fn sock ->
      {:ok, _} = :gen_tcp.recv(sock, 20, 1000)
      reply(sock, scenario)
    end)
  end

  def start_script(fun) do
    parent = self()

    pid =
      spawn_link(fn ->
        {:ok, listener} =
          :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

        {:ok, port} = :inet.port(listener)
        send(parent, {:listening, self(), port})

        try do
          {:ok, sock} = :gen_tcp.accept(listener)

          try do
            fun.(sock)
          after
            :gen_tcp.close(sock)
          end
        after
          :gen_tcp.close(listener)
        end
      end)

    ExUnit.Callbacks.on_exit(fn ->
      ref = Process.monitor(pid)
      Process.unlink(pid)
      Process.exit(pid, :shutdown)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      end
    end)

    receive do
      {:listening, ^pid, port} -> {:ok, port}
    end
  end

  defp reply(sock, :version_negotiation), do: :gen_tcp.send(sock, <<0, 0, 0, 0>>)
  defp reply(sock, :non_bolt), do: :gen_tcp.send(sock, "HTTP/1.1 400 Bad Request\r\n\r\n")
  defp reply(_, :stall), do: Process.sleep(:infinity)

  defp reply(sock, :garbled_hello) do
    :gen_tcp.send(sock, <<0, 0, 4, 4>>)
    _ = :gen_tcp.recv(sock, 0, 1000)
    # IGNORED with an illegal field carrying data: reject without retaining it.
    :gen_tcp.send(sock, <<0, 23, 0xB1, 0x7E, 0xD0, 19, "SERVER_HELLO_SECRET!", 0, 0>>)
  end

  defp reply(sock, :stall_after_handshake) do
    :gen_tcp.send(sock, <<0, 0, 4, 4>>)
    _ = :gen_tcp.recv(sock, 0, 1000)
    Process.sleep(:infinity)
  end
end
