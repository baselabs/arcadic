defmodule Arcadic.TransportError do
  @moduledoc """
  A transport/network failure with no HTTP response (connection refused, timeout,
  closed). `reason` is the underlying Mint/Finch reason atom — value-free.
  """

  defexception [:reason]

  @type t :: %__MODULE__{reason: atom()}

  @impl true
  @spec message(t()) :: String.t()
  def message(%__MODULE__{reason: reason}), do: "ArcadeDB transport error: #{inspect(reason)}"

  defimpl Inspect do
    def inspect(err, _opts), do: "#Arcadic.TransportError<#{inspect(err.reason)}>"
  end
end
