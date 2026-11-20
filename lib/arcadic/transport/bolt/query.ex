if Code.ensure_loaded?(DBConnection) do
  defmodule Arcadic.Transport.Bolt.Query do
    @moduledoc false
    @derive {Inspect, only: []}
    defstruct [:statement, extra: %{}]
    @type t :: %__MODULE__{statement: String.t(), extra: map()}
  end

  defimpl DBConnection.Query, for: Arcadic.Transport.Bolt.Query do
    def parse(query, _), do: query
    def describe(query, _), do: query
    def encode(_, params, _), do: params
    def decode(_, result, _), do: result
  end

  defimpl String.Chars, for: Arcadic.Transport.Bolt.Query do
    def to_string(_), do: "[BOLT]"
  end
end
