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
  alias Arcadic.{Conn, Opts}

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

  @doc """
  Returns the database engine config as a single map — `name`, `path`, `mode`, `dateFormat`,
  `dateTimeFormat`, `timezone`, `encoding`, and a `settings` list of `%{"key","value","description",
  "overridden","default"}`, `@props`-stripped at every depth. Returns the SINGLE config map.
  `SELECT FROM schema:database` is arcadic's own fixed literal (SQL-only) — no caller value interpolated.
  """
  @spec database(Conn.t()) :: {:ok, map()} | {:error, Exception.t()}
  def database(%Conn{} = conn) do
    case query(conn, "SELECT FROM schema:database") do
      {:ok, [cfg | _]} -> {:ok, cfg}
      {:ok, []} -> {:ok, %{}}
      {:error, _} = e -> e
    end
  end

  @doc "Returns the database config map, or raises."
  @spec database!(Conn.t()) :: map()
  def database!(%Conn{} = conn), do: bang(database(conn))

  @doc """
  Lists the properties of `type` (each with `name`, `type`, `default`, …), `@props`-stripped.
  `type` is `Arcadic.Identifier`-shape-guarded (a value-free `{:error, :invalid_identifier}` on a
  bad shape — the offending name is never echoed) AND bound as a `$param` — never interpolated.
  Returns `{:ok, []}` when the type does not exist (or has no properties); use `types/1` to
  distinguish absence from emptiness.
  """
  @spec properties(Conn.t(), String.t()) ::
          {:ok, [map()]} | {:error, Exception.t() | :invalid_identifier}
  def properties(%Conn{} = conn, type) do
    with :ok <- Arcadic.Identifier.validate(type),
         {:ok, rows} <-
           Arcadic.query(
             conn,
             "SELECT properties FROM schema:types WHERE name = :t",
             %{"t" => type},
             language: "sql"
           ) do
      {:ok, unwrap_properties(rows)}
    end
  end

  @doc "Lists the properties of `type`, returning them or raising."
  @spec properties!(Conn.t(), String.t()) :: [map()]
  def properties!(%Conn{} = conn, type), do: bang(properties(conn, type))

  @doc """
  Lists indexes, `@props`-stripped. Returns BOTH logical indexes (e.g. `Person[name]`, no
  `fileId`) AND physical per-bucket indexes (e.g. `Person_0_…`, carrying `fileId`/
  `associatedBucketId`) — faithful to `schema:indexes`. A caller wanting only logical indexes
  filters on the ABSENCE of the `fileId` key. `opts[:type]` restricts to one type by `typeName`
  (`Arcadic.Identifier`-shape-guarded, bound as a `$param`).
  """
  @spec indexes(Conn.t(), keyword()) ::
          {:ok, [map()]} | {:error, Exception.t() | :invalid_identifier}
  def indexes(%Conn{} = conn, opts \\ []) do
    Opts.validate_keys!(opts, [:type])

    case Keyword.fetch(opts, :type) do
      :error ->
        query(conn, "SELECT FROM schema:indexes")

      {:ok, type} ->
        with :ok <- Arcadic.Identifier.validate(type) do
          query(conn, "SELECT FROM schema:indexes WHERE typeName = :t", %{"t" => type})
        end
    end
  end

  @doc "Lists indexes, returning them or raising."
  @spec indexes!(Conn.t(), keyword()) :: [map()]
  def indexes!(%Conn{} = conn, opts \\ []), do: bang(indexes(conn, opts))

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

  # schema:types projects the properties column as a single WRAPPED row [%{"properties" => [...]}]
  # (probed live). Un-nest to the bare property list and deep-strip each. Absent type → no row → [].
  defp unwrap_properties([%{"properties" => props} | _]) when is_list(props),
    do: Enum.map(props, &strip_props_deep/1)

  defp unwrap_properties(_), do: []

  defp bang({:ok, rows}), do: rows
  defp bang({:error, %{__exception__: true} = error}), do: raise(error)

  defp bang({:error, reason}),
    do: raise(ArgumentError, "schema operation failed: #{inspect(reason)}")
end
