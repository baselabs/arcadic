defmodule Arcadic.Test.Opaque do
  @moduledoc false

  # Returns `value` with its static type erased. A test that hands a guard a deliberately
  # wrong type passes it through here, so the compiler's type checker does not flag the
  # call site and the runtime guard is what rejects it.
  @spec value(term()) :: term()
  def value(value), do: :erlang.binary_to_term(:erlang.term_to_binary(value))
end
