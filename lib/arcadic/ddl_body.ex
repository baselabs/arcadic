defmodule Arcadic.DDLBody do
  @moduledoc false
  # Reject-not-escape guard for ArcadeDB DDL body literals (DEFINE FUNCTION "body",
  # CREATE TRIGGER ... EXECUTE <lang> "code"). ArcadeDB's "..." body literal has NO escape
  # (probed: \", "", newline all parse-error), so the ONLY safe embedding is to reject any
  # input that cannot sit inside "..." single-line. Positive allowlist: any character EXCEPT
  # the double-quote (the sole breakout byte), the backslash, and control/line bytes (which
  # parse-error server-side). Non-ASCII printable is ALLOWED (no ASCII narrowing).
  # \p{Cc} = control, \x{2028}\x{2029} = line/paragraph separators.
  #
  # An invalid-UTF-8 binary satisfies the `is_binary` type contract but makes the `/u`-flag
  # `Regex.match?` RAISE an opaque `:re` "argument error" — so it is short-circuit-rejected
  # value-free as `{:error, :unencodable_body}` BEFORE the regex runs (same non-UTF-8
  # convention as `security.ex:95-103`: discard the error, return a value-free reason).
  @forbidden ~r/["\\\p{Cc}\x{2028}\x{2029}]/u

  @doc """
  `{:ok, body}` if the body embeds in a `"..."` DDL literal, else `{:error, :unencodable_body}`
  (value-free — the bare atom never echoes the body). A non-binary body is a caller-contract
  violation and RAISES value-free (mirrors `full_text.ex:125`'s non-list total fallback),
  guarded FIRST so a wrong-type never reaches `Regex.match?` (the recurring Rule-3 head-guard class).
  """
  @spec encode(term()) :: {:ok, String.t()} | {:error, :unencodable_body}
  def encode(body) when is_binary(body) do
    if String.valid?(body) and not Regex.match?(@forbidden, body),
      do: {:ok, body},
      else: {:error, :unencodable_body}
  end

  def encode(_body), do: raise(ArgumentError, "body must be a string")
end
