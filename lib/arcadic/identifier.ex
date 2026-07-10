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

  @url_schemes ~w(http https file)
  # RFC 3986 URL characters MINUS the single quote and backslash (ArcadeDB honors backslash-escapes
  # inside a quoted literal). Excludes ALL whitespace + control by construction — a bare rest-of-line
  # restore URL cannot form a second server command (whose tokens need whitespace), regardless of how
  # the server treats an in-token `;`/`#`.
  @url_pattern ~r/\A[A-Za-z0-9\-._~:\/?#\[\]@!$&()*+,;=%]+\z/
  @max_url_length 2048
  # Setting keys are dotted (arcadedb.server.foo) — the identifier pattern rejects dots, so a
  # dot-allowing positive allowlist; excludes backtick/space/control (the set-setting quoting context).
  @setting_key_pattern ~r/\A[A-Za-z][A-Za-z0-9_.]{0,127}\z/

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

  @doc """
  Validates a URL for interpolation into an `IMPORT`/`BACKUP`/`restore` command. Positive
  RFC-3986 allowlist + scheme allowlist (`http`/`https`/`file`); value-free reasons.
  """
  @spec validate_url(term()) ::
          :ok
          | {:error,
             :empty | :too_long | :invalid_chars | :invalid_scheme | :invalid_uri | :not_a_string}
  def validate_url(url) when is_binary(url) do
    cond do
      String.trim(url) == "" -> {:error, :empty}
      String.length(url) > @max_url_length -> {:error, :too_long}
      not Regex.match?(@url_pattern, url) -> {:error, :invalid_chars}
      true -> validate_url_scheme(url)
    end
  end

  def validate_url(_url), do: {:error, :not_a_string}

  defp validate_url_scheme(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme}} when scheme in @url_schemes -> :ok
      {:ok, %URI{}} -> {:error, :invalid_scheme}
      {:error, _} -> {:error, :invalid_uri}
    end
  end

  @doc "Validates a server/database setting KEY (dotted allowlist); value-free."
  @spec validate_setting_key(term()) :: :ok | {:error, :invalid_setting_key}
  def validate_setting_key(key) when is_binary(key) do
    if Regex.match?(@setting_key_pattern, key), do: :ok, else: {:error, :invalid_setting_key}
  end

  def validate_setting_key(_key), do: {:error, :invalid_setting_key}
end
