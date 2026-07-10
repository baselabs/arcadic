defmodule Arcadic.Server do
  @moduledoc """
  Server-level admin: create/drop/list databases, existence, readiness. Every
  identifier is allowlist-validated BEFORE any request reaches the wire (fixes the
  interpolation surface a hand-written `create database <name>` would open). Returns
  are tagged tuples — a transport failure is never swallowed into a bare boolean.
  Not delegated from the `Arcadic` facade: destructive admin stays namespaced.
  """

  alias Arcadic.{Admin, Conn, Identifier, Opts}

  @doc "Create a database. Validates `name`."
  @spec create_database(Conn.t(), String.t()) :: :ok | {:error, atom() | Exception.t()}
  def create_database(%Conn{} = conn, name),
    do:
      with_valid(name, fn ->
        Admin.span(:create_database, fn ->
          Admin.to_ok(Admin.command(conn, "create database #{name}"))
        end)
      end)

  @doc "Create a database, raising on error."
  @spec create_database!(Conn.t(), String.t()) :: :ok
  def create_database!(%Conn{} = conn, name), do: bang(create_database(conn, name))

  @doc "Drop a database. Validates `name`."
  @spec drop_database(Conn.t(), String.t()) :: :ok | {:error, atom() | Exception.t()}
  def drop_database(%Conn{} = conn, name),
    do:
      with_valid(name, fn ->
        Admin.span(:drop_database, fn ->
          Admin.to_ok(Admin.command(conn, "drop database #{name}"))
        end)
      end)

  @doc "Drop a database, raising on error."
  @spec drop_database!(Conn.t(), String.t()) :: :ok
  def drop_database!(%Conn{} = conn, name), do: bang(drop_database(conn, name))

  @doc "Whether a database exists."
  @spec database_exists?(Conn.t(), String.t()) ::
          {:ok, boolean()} | {:error, atom() | Exception.t()}
  def database_exists?(%Conn{} = conn, name),
    do:
      with_valid(name, fn ->
        Admin.span(:database_exists?, fn -> conn.transport.database_exists?(conn, name) end)
      end)

  @doc "List all databases."
  @spec list_databases(Conn.t()) :: {:ok, [String.t()]} | {:error, Exception.t()}
  def list_databases(%Conn{} = conn),
    do: Admin.span(:list_databases, fn -> conn.transport.list_databases(conn) end)

  @doc "Server readiness."
  @spec ready?(Conn.t()) :: {:ok, boolean()} | {:error, Exception.t()}
  def ready?(%Conn{} = conn), do: Admin.span(:ready?, fn -> conn.transport.ready?(conn) end)

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

  @doc """
  Set a server-level setting (`set server setting \`k\` \`v\``). `key` is allowlist-validated
  (dotted), `value` must be printable ASCII without a backtick or backslash (the backtick-quoting
  context) — both rejected value-free (`{:error, :invalid_setting_key | :invalid_setting_value}`).
  """
  @spec set_server_setting(Conn.t(), String.t(), String.t()) ::
          :ok | {:error, atom() | Exception.t()}
  def set_server_setting(%Conn{} = conn, key, value) do
    with :ok <- valid_setting_key(key), :ok <- valid_setting_value(value) do
      Admin.span(:set_server_setting, fn ->
        Admin.to_ok(Admin.command(conn, "set server setting `#{key}` `#{value}`"))
      end)
    end
  end

  @doc "Set a setting on `conn.database` (`set database setting <db> \`k\` \`v\``). Guards as `set_server_setting/3`."
  @spec set_database_setting(Conn.t(), String.t(), String.t()) ::
          :ok | {:error, atom() | Exception.t()}
  def set_database_setting(%Conn{} = conn, key, value) do
    with :ok <- valid_setting_key(key), :ok <- valid_setting_value(value) do
      Admin.span(:set_database_setting, fn ->
        Admin.to_ok(
          Admin.command(conn, "set database setting #{conn.database} `#{key}` `#{value}`")
        )
      end)
    end
  end

  @doc "Open a closed database on the server. Validates `name`."
  @spec open_database(Conn.t(), String.t()) :: :ok | {:error, atom() | Exception.t()}
  def open_database(%Conn{} = conn, name),
    do:
      with_valid(name, fn ->
        Admin.span(:open_database, fn ->
          Admin.to_ok(Admin.command(conn, "open database #{name}"))
        end)
      end)

  @doc "Close an open database on the server. Validates `name`."
  @spec close_database(Conn.t(), String.t()) :: :ok | {:error, atom() | Exception.t()}
  def close_database(%Conn{} = conn, name),
    do:
      with_valid(name, fn ->
        Admin.span(:close_database, fn ->
          Admin.to_ok(Admin.command(conn, "close database #{name}"))
        end)
      end)

  @doc """
  Cluster-realign a database. **CLUSTER-ONLY** — a single-server node returns a server error
  (`java.lang.UnsupportedOperationException`, surfaced as `{:error, %Arcadic.Error{reason: :server_error}}`).
  Validates `name`.
  """
  @spec align_database(Conn.t(), String.t()) :: {:ok, map()} | {:error, atom() | Exception.t()}
  def align_database(%Conn{} = conn, name),
    do:
      with_valid(name, fn ->
        Admin.span(:align_database, fn -> Admin.command(conn, "align database #{name}") end)
      end)

  @doc "Run `CHECK DATABASE [FIX]` on `conn.database`. `fix: true` repairs. Returns the integrity map."
  @spec check_database(Conn.t(), keyword()) :: {:ok, map()} | {:error, Exception.t()}
  def check_database(%Conn{} = conn, opts \\ []) do
    Opts.validate_keys!(opts, [:fix])
    statement = if opts[:fix] == true, do: "CHECK DATABASE FIX", else: "CHECK DATABASE"

    Admin.span(:check_database, fn ->
      with {:ok, rows} <- Admin.sql(conn, statement), do: {:ok, List.first(rows, %{})}
    end)
  end

  @profiler_actions ~w(results start stop reset)a

  @doc "Control the server profiler. `action` ∈ #{inspect(@profiler_actions)}."
  @spec profiler(Conn.t(), atom()) :: {:ok, map()} | {:error, Exception.t()}
  def profiler(%Conn{} = conn, action) when action in @profiler_actions,
    do: Admin.span(:profiler, fn -> Admin.command(conn, "profiler #{action}") end)

  def profiler(%Conn{} = _conn, _action),
    do: raise(ArgumentError, "profiler action must be one of #{inspect(@profiler_actions)}")

  @doc """
  Shut the server down (`shutdown`). **DESTRUCTIVE — halts shared infrastructure.** The server stops
  responding mid-request, so a SUCCESSFUL shutdown typically surfaces as
  `{:error, %Arcadic.TransportError{reason: :closed}}` (connection reset), not `:ok` — treat a
  transport-closed error here as success, not a retryable failure.
  """
  @spec shutdown(Conn.t()) :: :ok | {:error, Exception.t()}
  def shutdown(%Conn{} = conn),
    do: Admin.span(:shutdown, fn -> Admin.to_ok(Admin.command(conn, "shutdown")) end)

  defp with_valid(name, fun) do
    case Identifier.validate(name) do
      :ok -> fun.()
      {:error, :invalid_identifier} = err -> err
    end
  end

  defp valid_setting_key(key) do
    case Identifier.validate_setting_key(key) do
      :ok -> :ok
      {:error, _} -> {:error, :invalid_setting_key}
    end
  end

  # Positive posture: printable ASCII (0x20-0x7E) MINUS backtick + backslash (mirrors Import's
  # single-quote-literal exclusion of `'`/`\`). Rejects control/newline/non-ASCII too. Value-free.
  defp valid_setting_value(v) when is_binary(v) do
    cond do
      not Regex.match?(~r/\A[ -~]*\z/, v) -> {:error, :invalid_setting_value}
      String.contains?(v, "`") or String.contains?(v, "\\") -> {:error, :invalid_setting_value}
      true -> :ok
    end
  end

  defp valid_setting_value(_), do: {:error, :invalid_setting_value}

  defp bang(:ok), do: :ok
  defp bang({:error, %{__exception__: true} = error}), do: raise(error)

  defp bang({:error, reason}),
    do: raise(ArgumentError, "server operation failed: #{inspect(reason)}")
end
