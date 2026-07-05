defmodule Arcadic.Opts do
  @moduledoc false
  # Shared, value-free option-key guard for every opts-taking public function
  # (`Arcadic.query`/`command`/`query_stream`, `Arcadic.Schema`, `Arcadic.Import`,
  # `Arcadic.Vector`). Extracted 2026-07-05 from four near-identical private copies.

  @doc false
  # Raises a value-free `ArgumentError` unless `opts` is a keyword list whose keys are all in
  # `allowed`; returns `:ok`. Guards the SHAPE with `Keyword.keyword?/1` BEFORE `Keyword.keys/1`:
  # on an improper list (a non-atom key or a non-tuple element) `Keyword.keys/1` raises a message
  # that ECHOES the offending entry — a Rule-3 caller-value leak (AGENTS.md Rule 3). Unknown keys
  # are reported by option NAME only (never a caller value).
  @spec validate_keys!(term(), [atom()]) :: :ok
  def validate_keys!(opts, allowed) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "opts must be a keyword list"
    end

    case Keyword.keys(opts) -- allowed do
      [] ->
        :ok

      bad ->
        raise ArgumentError, "unknown option(s) #{inspect(bad)}; allowed: #{inspect(allowed)}"
    end
  end
end
