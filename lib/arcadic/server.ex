defmodule Arcadic.Server do
  @moduledoc """
  Server-level admin: create/drop/list databases, existence, readiness. Every
  identifier is allowlist-validated BEFORE any request reaches the wire (fixes the
  interpolation surface a hand-written `create database <name>` would open). Returns
  are tagged tuples — a transport failure is never swallowed into a bare boolean.
  Not delegated from the `Arcadic` facade: destructive admin stays namespaced.
  """

  alias Arcadic.{Conn, Identifier}

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
