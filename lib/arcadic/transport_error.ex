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

  # Value-free fallback: a wrong-typed argument raises instead of echoing it via
  # FunctionClauseError blame.
  def message(other) when not is_struct(other, __MODULE__),
    do: raise(ArgumentError, "expected an Arcadic.TransportError")

  defimpl Inspect do
    def inspect(err, _opts), do: "#Arcadic.TransportError<#{inspect(err.reason)}>"
  end
end
