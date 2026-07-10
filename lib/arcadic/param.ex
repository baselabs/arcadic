defmodule Arcadic.Param do
  @moduledoc """
  Constructors for ArcadeDB's typed-JSON param **value-wrappers** — an efficient way to
  send a byte array or an INT8-quantized vector as a bound parameter instead of a verbose
  JSON number array.

  A param VALUE that is a single-key JSON object `{"$int8" => …}` or `{"$bytes" => …}` is
  decoded server-side to a Java `byte[]` **before** the query runs (ArcadeDB's HTTP command
  handler). The statement still references the parameter by the normal per-language
  placeholder (`:name` for SQL, `$name` for Cypher):

      # SQL: insert an int8 vector into a BINARY property
      Arcadic.command(conn, "INSERT INTO Doc SET embedding = :e", %{"e" => Arcadic.Param.int8([0, 64, 127, -1, -128])}, language: "sql")

  ## Caveats (documented, not enforced)

  - **HTTP transport only.** The decode lives in ArcadeDB's HTTP handler; the marker is inert
    over Bolt (Bolt sends the map through unchanged).
  - **Requires ArcadeDB ≥ 26.5.1** (the marker decode shipped in 26.5.1).
  - **Ambient single-key collision.** ArcadeDB decodes ANY single-key `{"$int8" => …}` /
    `{"$bytes" => …}` in `params` — so a legitimate caller value that happens to be exactly a
    single-key map with that key is reinterpreted as a `byte[]`. `Arcadic.Param` does not cause
    this (it exposes the same server behavior arcadic's plain param passthrough already exposes);
    add a second key to a map you want left untouched.
  """

  @doc """
  Wrap a list of signed-byte integers (each in `-128..127`) as the `$int8` marker
  `%{"$int8" => list}`. Raises `ArgumentError` (value-free) on a non-list or an out-of-range /
  non-integer element — client-side so the offending value never reaches the server 400 (which
  echoes it).
  """
  @spec int8([integer()]) :: %{String.t() => [integer()]}
  def int8(list) when is_list(list) do
    Enum.each(list, fn
      n when is_integer(n) and n >= -128 and n <= 127 -> :ok
      _ -> raise ArgumentError, "int8 elements must be integers in -128..127"
    end)

    %{"$int8" => list}
  end

  def int8(_), do: raise(ArgumentError, "int8/1 requires a list of integers in -128..127")

  @doc "Base64-encode a binary as the `$bytes` marker `%{\"$bytes\" => base64}`. Raises value-free on a non-binary."
  @spec bytes(binary()) :: %{String.t() => String.t()}
  def bytes(bin) when is_binary(bin), do: %{"$bytes" => Base.encode64(bin)}
  def bytes(_), do: raise(ArgumentError, "bytes/1 requires a binary")
end
