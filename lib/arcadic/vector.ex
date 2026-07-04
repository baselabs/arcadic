defmodule Arcadic.Vector do
  @moduledoc """
  ArcadeDB dense vector search — tenant-blind index DDL and nearest-neighbour /
  hybrid-fusion query builders over ArcadeDB's `LSM_VECTOR` surface.

  Every caller value (query vector, `k`, `ef_search`, `max_distance`) binds as a
  `$param`. The only text interpolated into a statement is the index reference
  `"Type[property]"`, whose two identifiers are `Arcadic.Identifier`-validated before
  composition — the sole injection surface, closed by construction (callers pass
  `type`/`property`, never a raw ref). Index metadata values (`dimensions`, the
  similarity/encoding/quantization enums) are developer-supplied schema config,
  validated against integer/allowlist checks before interpolation. Failures carry the
  invalid SHAPE only, never the offending value (AGENTS.md Critical Rule 3).
  """
  alias Arcadic.Identifier

  @doc "Builds the ArcadeDB index reference `\"Type[property]\"`, validating both identifiers."
  @spec index_ref(String.t(), String.t()) :: {:ok, String.t()} | {:error, :invalid_identifier}
  def index_ref(type, property) do
    with :ok <- Identifier.validate(type),
         :ok <- Identifier.validate(property) do
      {:ok, "#{type}[#{property}]"}
    end
  end
end
