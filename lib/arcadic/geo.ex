defmodule Arcadic.Geo do
  @moduledoc """
  ArcadeDB geospatial index DDL — tenant-blind `GEOSPATIAL` index create/drop, parallel to
  `Arcadic.FullText`'s single-property form.

  The type/property names are the only injection surfaces (interpolated behind
  `Arcadic.Identifier`, closed by construction) — `GEOSPATIAL` indexes take no query text, so there
  is no params-binding surface analogous to `FULL_TEXT`'s `SEARCH_INDEX`. Geospatial querying itself
  (e.g. a `distance(...)` computation or the `geo.*` predicate family) rides ordinary
  `Arcadic.query/4` and is out of scope here.
  """
  alias Arcadic.{Conn, Identifier, Opts}

  @create_opts [:if_not_exists]

  @doc """
  Creates a `GEOSPATIAL` index on `type.property` (idempotent — `IF NOT EXISTS` unless
  `if_not_exists: false`). Value-free on a bad identifier / unknown opt.
  """
  @spec create_index(Conn.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, atom() | Exception.t()}
  def create_index(%Conn{} = conn, type, property, opts \\ []) do
    Opts.validate_keys!(opts, @create_opts)

    with :ok <- Identifier.validate(type),
         :ok <- Identifier.validate(property) do
      guard = if Keyword.get(opts, :if_not_exists, true), do: " IF NOT EXISTS", else: ""
      command_ok(conn, "CREATE INDEX#{guard} ON #{type} (#{property}) GEOSPATIAL")
    end
  end

  @doc "Creates a GEOSPATIAL index, raising on error."
  @spec create_index!(Conn.t(), String.t(), String.t(), keyword()) :: :ok
  def create_index!(%Conn{} = conn, type, property, opts \\ []),
    do: bang(create_index(conn, type, property, opts))

  @doc "Drops a GEOSPATIAL index (idempotent — `IF EXISTS`)."
  @spec drop_index(Conn.t(), String.t(), String.t()) :: :ok | {:error, atom() | Exception.t()}
  def drop_index(%Conn{} = conn, type, property) do
    with :ok <- Identifier.validate(type),
         :ok <- Identifier.validate(property) do
      command_ok(conn, "DROP INDEX `#{type}[#{property}]` IF EXISTS")
    end
  end

  @doc "Drops a GEOSPATIAL index, raising on error."
  @spec drop_index!(Conn.t(), String.t(), String.t()) :: :ok
  def drop_index!(%Conn{} = conn, type, property),
    do: bang(drop_index(conn, type, property))

  # --- private ---

  defp command_ok(conn, statement) do
    case Arcadic.command(conn, statement, %{}, language: "sql") do
      {:ok, _rows} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp bang(:ok), do: :ok
  defp bang({:error, %{__exception__: true} = error}), do: raise(error)

  defp bang({:error, reason}),
    do: raise(ArgumentError, "geo operation failed: #{inspect(reason)}")
end
