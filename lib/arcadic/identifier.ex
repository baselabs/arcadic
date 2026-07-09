defmodule Arcadic.Identifier do
  @moduledoc """
  Allowlist validation for identifiers arcadic places into a URL path or a
  statement (database names, labels, property names).

  Values are never identifiers — they ride the `params` map. This guards the
  identifier surface only (AGENTS.md Critical Rule 2). A failure carries the
  invalid-SHAPE fact only, never the offending string (it may be attacker-
  controlled or contain a secret).
  """

  # First char a letter, then up to 127 letters/digits/underscores (128 total).
  @pattern ~r/\A[A-Za-z][A-Za-z0-9_]{0,127}\z/

  @doc """
  Returns `:ok` for a valid identifier, `{:error, :invalid_identifier}` otherwise.

  ## Examples

      iex> Arcadic.Identifier.validate("Person")
      :ok
      iex> Arcadic.Identifier.validate("1bad")
      {:error, :invalid_identifier}

  """
  @spec validate(term()) :: :ok | {:error, :invalid_identifier}
  def validate(value) when is_binary(value) do
    if Regex.match?(@pattern, value), do: :ok, else: {:error, :invalid_identifier}
  end

  def validate(_value), do: {:error, :invalid_identifier}

  @doc "Boolean form of `validate/1`."
  @spec valid?(term()) :: boolean()
  def valid?(value), do: validate(value) == :ok
end
