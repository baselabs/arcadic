defmodule Arcadic.Migrator do
  @moduledoc """
  Runs `Arcadic.Migration`s in order and tracks applied versions in the
  `_arcadic_migrations` document type. Tenant-blind: it runs DDL/DML and records
  integer versions — no tenant, scope, or Ash concept. Assumes single-process,
  deploy-time execution (like every migration tool); it does not take an advisory
  lock, so do not run two migrators concurrently against one database.
  """

  alias Arcadic.Conn

  @type_name "_arcadic_migrations"

  @doc "Run all pending migrations (up). Returns `{:ok, count_run}`."
  @spec migrate(Conn.t(), module()) :: {:ok, non_neg_integer()} | {:error, Exception.t()}
  def migrate(%Conn{} = conn, registry) when is_atom(registry) do
    with :ok <- ensure_type(conn),
         {:ok, applied} <- applied_versions(conn) do
      run_up(conn, pending_migrations(registry.migrations(), applied), 0)
    end
  end

  @doc "Status of each registered migration: `{version, :up | :down}`, ascending."
  @spec status(Conn.t(), module()) ::
          {:ok, [{pos_integer(), :up | :down}]} | {:error, Exception.t()}
  def status(%Conn{} = conn, registry) when is_atom(registry) do
    with :ok <- ensure_type(conn),
         {:ok, applied} <- applied_versions(conn) do
      statuses =
        registry.migrations()
        |> Enum.sort_by(& &1.version())
        |> Enum.map(fn mod ->
          {mod.version(), if(mod.version() in applied, do: :up, else: :down)}
        end)

      {:ok, statuses}
    end
  end

  @doc "Registered migrations not yet applied, ascending by version (pure)."
  @spec pending_migrations([module()], [integer()]) :: [module()]
  def pending_migrations(mods, applied) do
    mods
    |> Enum.sort_by(& &1.version())
    |> Enum.reject(fn mod -> mod.version() in applied end)
  end

  defp run_up(_conn, [], count), do: {:ok, count}

  defp run_up(conn, [mod | rest], count) do
    with :ok <- mod.up(conn),
         :ok <- record_version(conn, mod.version()) do
      run_up(conn, rest, count + 1)
    end
  end

  # @type_name is a fixed literal, never user input — safe to interpolate.
  defp ensure_type(conn) do
    tracked(conn, "CREATE DOCUMENT TYPE #{@type_name} IF NOT EXISTS")
  end

  defp applied_versions(conn) do
    case Arcadic.command(conn, "SELECT version FROM #{@type_name} ORDER BY version", %{},
           language: "sql"
         ) do
      {:ok, rows} -> {:ok, Enum.map(rows, & &1["version"])}
      {:error, error} -> {:error, error}
    end
  end

  defp record_version(conn, version) do
    tracked(conn, "INSERT INTO #{@type_name} SET version = :v, applied_at = sysdate()", %{
      "v" => version
    })
  end

  defp tracked(conn, sql, params \\ %{}) do
    case Arcadic.command(conn, sql, params, language: "sql") do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end
end
