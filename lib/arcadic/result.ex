defmodule Arcadic.Result do
  @moduledoc """
  Normalizes an ArcadeDB command/query response envelope into a list of rows.

  Strips `@props` (serializer noise on projection rows) but KEEPS the record and
  graph identity keys the data layer needs: `@rid`, `@type`, `@cat` (`"v"`/`"e"`),
  `@in`, `@out` (edges only). Probe-verified — spec §15 P4/P5/P15.
  """

  @stripped_keys ~w(@props)

  @doc "Extract `result`, strip `@props` per row; return `{:ok, rows}`."
  @spec normalize(map()) :: {:ok, [map()]}
  def normalize(body) when is_map(body) do
    rows =
      body
      |> Map.get("result", [])
      |> Enum.map(&strip_row/1)

    {:ok, rows}
  end

  defp strip_row(row) when is_map(row), do: Map.drop(row, @stripped_keys)
  defp strip_row(row), do: row
end
