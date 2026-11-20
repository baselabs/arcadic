defmodule Arcadic.Transport.Bolt.Framing do
  @moduledoc false
  alias Arcadic.TransportError

  @max_message 64 * 1024 * 1024

  def encode(data) when is_binary(data), do: chunks(data, [])

  defp chunks(<<>>, acc), do: Enum.reverse([<<0, 0>> | acc])

  defp chunks(data, acc) do
    n = min(byte_size(data), 65_535)
    <<chunk::binary-size(n), rest::binary>> = data
    chunks(rest, [[<<n::16>>, chunk] | acc])
  end

  def deadline(:infinity), do: :infinity
  def deadline(timeout), do: System.monotonic_time(:millisecond) + timeout
  def remaining(:infinity), do: :infinity
  def remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  def recv(socket, deadline), do: recv_chunks(socket, deadline, [], 0)

  def read({mod, sock}, n, deadline) do
    case remaining(deadline) do
      0 -> {:error, :timeout}
      timeout -> mod.recv(sock, n, timeout)
    end
  end

  defp recv_chunks(socket, deadline, acc, size) do
    with {:ok, <<n::16>>} <- read(socket, 2, deadline) do
      receive_chunk(n, socket, deadline, acc, size)
    end
  end

  # Zero chunks between messages are Bolt NOOPs; inside a message they end it.
  defp receive_chunk(0, socket, deadline, [], 0), do: recv_chunks(socket, deadline, [], 0)
  defp receive_chunk(0, _, _, acc, _), do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

  defp receive_chunk(n, socket, deadline, acc, size)
       when size + n <= @max_message do
    with {:ok, chunk} <- read(socket, n, deadline),
         do: recv_chunks(socket, deadline, [chunk | acc], size + n)
  end

  defp receive_chunk(_, _, _, _, _), do: {:error, %TransportError{reason: :bolt_protocol_error}}
end
