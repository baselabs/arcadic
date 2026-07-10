defmodule Arcadic.Server do
  @moduledoc """
  Server-level admin: create/drop/list databases, existence, readiness. Every
  identifier is allowlist-validated BEFORE any request reaches the wire (fixes the
  interpolation surface a hand-written `create database <name>` would open). Returns
  are tagged tuples — a transport failure is never swallowed into a bare boolean.
  Not delegated from the `Arcadic` facade: destructive admin stays namespaced.
  """

  alias Arcadic.{Admin, Conn, Identifier}

  @doc "Create a database. Validates `name`."
  @spec create_database(Conn.t(), String.t()) :: :ok | {:error, atom() | Exception.t()}
  def create_database(%Conn{} = conn, name),
    do: with_valid(name, fn -> command_ok(conn, "create database #{name}") end)

  @doc "Create a database, raising on error."
  @spec create_database!(Conn.t(), String.t()) :: :ok
  def create_database!(%Conn{} = conn, name), do: bang(create_database(conn, name))

  @doc "Drop a database. Validates `name`."
  @spec drop_database(Conn.t(), String.t()) :: :ok | {:error, atom() | Exception.t()}
  def drop_database(%Conn{} = conn, name),
    do: with_valid(name, fn -> command_ok(conn, "drop database #{name}") end)

  @doc "Drop a database, raising on error."
  @spec drop_database!(Conn.t(), String.t()) :: :ok
  def drop_database!(%Conn{} = conn, name), do: bang(drop_database(conn, name))

  @doc "Whether a database exists."
  @spec database_exists?(Conn.t(), String.t()) ::
          {:ok, boolean()} | {:error, atom() | Exception.t()}
  def database_exists?(%Conn{} = conn, name),
    do: with_valid(name, fn -> conn.transport.database_exists?(conn, name) end)

  @doc "List all databases."
  @spec list_databases(Conn.t()) :: {:ok, [String.t()]} | {:error, Exception.t()}
  def list_databases(%Conn{} = conn), do: conn.transport.list_databases(conn)

  @doc "Server readiness."
  @spec ready?(Conn.t()) :: {:ok, boolean()} | {:error, Exception.t()}
  def ready?(%Conn{} = conn), do: conn.transport.ready?(conn)

  @modes ~w(basic default cluster)a

  @doc "Server info map. `:mode` ∈ #{inspect(@modes)} (default `:basic`); `:default`/`:cluster` add metrics/settings."
  @spec info(Conn.t(), keyword()) :: {:ok, map()} | {:error, Exception.t()}
  def info(%Conn{} = conn, opts \\ []) do
    mode = Keyword.get(opts, :mode, :basic)
    unless mode in @modes, do: raise(ArgumentError, "mode must be one of #{inspect(@modes)}")
    Admin.span(:info, fn -> Admin.get(conn, "/api/v1/server?mode=#{mode}") end)
  end

  @doc "The server metrics map (`info(conn, mode: :default)[\"metrics\"]`)."
  @spec metrics(Conn.t()) :: {:ok, map()} | {:error, Exception.t()}
  def metrics(%Conn{} = conn) do
    with {:ok, info} <- info(conn, mode: :default), do: {:ok, Map.get(info, "metrics", %{})}
  end

  @doc "Liveness probe (`GET /api/v1/health` → 204)."
  @spec health?(Conn.t()) :: {:ok, boolean()} | {:error, Exception.t()}
  def health?(%Conn{} = conn), do: Admin.call(conn, :health?)

  @doc ~S|Server event log map (`%{"events" => [...], "files" => [...]}`).|
  @spec events(Conn.t()) :: {:ok, map()} | {:error, Exception.t()}
  def events(%Conn{} = conn),
    do: Admin.span(:events, fn -> Admin.result(Admin.command(conn, "get server events")) end)

  defp command_ok(conn, command) do
    case conn.transport.server_command(conn, command) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp with_valid(name, fun) do
    case Identifier.validate(name) do
      :ok -> fun.()
      {:error, :invalid_identifier} = err -> err
    end
  end

  defp bang(:ok), do: :ok
  defp bang({:error, %{__exception__: true} = error}), do: raise(error)

  defp bang({:error, reason}),
    do: raise(ArgumentError, "server operation failed: #{inspect(reason)}")
end
