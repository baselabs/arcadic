defmodule Arcadic.Schema do
  @moduledoc """
  Read-only introspection of ArcadeDB schema metadata — types, properties, indexes, and
  buckets — over the SQL `SELECT FROM schema:*` surface (Cypher does not parse it).

  Tenant-blind, like every arcadic module: it reflects the server's metadata rows faithfully.
  The `schema:*` selector is arcadic's own fixed literal — no caller value is ever interpolated.
  Where a function accepts a caller-supplied type name, that name binds as a `$param` and is
  additionally `Arcadic.Identifier`-shape-guarded (value-free). Every returned row is
  `@props`-stripped at all nesting depths (ArcadeDB's serializer emits an `@props` count hint on
  the row and inside each nested `properties`/`indexes` object).
  """
  alias Arcadic.Conn

  @doc """
  Lists every type (vertex / edge / document). Each row carries `name`, `type`, `records`,
  `buckets`, `properties`, `indexes`, and the type's other metadata, `@props`-stripped.
  """
  @spec types(Conn.t()) :: {:ok, [map()]} | {:error, Exception.t()}
  def types(%Conn{} = conn), do: query(conn, "SELECT FROM schema:types")

  @doc "Lists every type, returning the rows or raising."
  @spec types!(Conn.t()) :: [map()]
  def types!(%Conn{} = conn), do: bang(types(conn))

  @doc "Lists the physical buckets (`name`, `fileId`, `records`, `purpose`), `@props`-stripped."
  @spec buckets(Conn.t()) :: {:ok, [map()]} | {:error, Exception.t()}
  def buckets(%Conn{} = conn), do: query(conn, "SELECT FROM schema:buckets")

  @doc "Lists the physical buckets, returning the rows or raising."
  @spec buckets!(Conn.t()) :: [map()]
  def buckets!(%Conn{} = conn), do: bang(buckets(conn))

  # Runs a fixed schema:* SELECT (SQL-only) and deep-strips @props from every returned row.
  defp query(%Conn{} = conn, statement, params \\ %{}) do
    case Arcadic.query(conn, statement, params, language: "sql") do
      {:ok, rows} -> {:ok, Enum.map(rows, &strip_props_deep/1)}
      {:error, _} = error -> error
    end
  end

  # Recursively drops the serializer-noise "@props" key at every depth, preserving every other
  # key. Only ever run on arcadic's own fixed schema:* rows (never arbitrary user rows), so a
  # user-stored key literally named "@props" cannot be reached.
  defp strip_props_deep(%{} = map) do
    map
    |> Map.delete("@props")
    |> Map.new(fn {k, v} -> {k, strip_props_deep(v)} end)
  end

  defp strip_props_deep(list) when is_list(list), do: Enum.map(list, &strip_props_deep/1)
  defp strip_props_deep(other), do: other

  defp bang({:ok, rows}), do: rows
  defp bang({:error, %{__exception__: true} = error}), do: raise(error)
end
