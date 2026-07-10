defmodule Arcadic.Security do
  @moduledoc """
  Server security & auth admin: session login/logout, active sessions, and user/group/API-token
  management — over ArcadeDB's HTTP admin surface. Reads (`users`/`groups`/`api_tokens`/`sessions`)
  use the read-only REST endpoints; mutations (`create_user`/`drop_user`) use server commands (the
  REST paths are read-only — `POST /server/users` → 400). Tenant-blind.

  `create_user/2` is the one place a caller VALUE (the password) reaches a statement: server commands
  cannot bind params (probed), so the user spec is `Jason.encode`d into `create user <json>` — the
  JSON backslash-escaping round-trips exactly against ArcadeDB's `create user` lexer (live-verified).
  The encode uses the NON-raising `Jason.encode/1`: a non-UTF8 binary password passes the `is_binary`
  guard but would make `Jason.encode!` raise a `Jason.EncodeError` that renders the raw bytes, so an
  unencodable spec is rejected value-free as `{:error, :invalid_user_spec}` (the Jason error, which
  holds the bytes, is discarded) before any wire call. The password NEVER enters an error, log, or
  telemetry line (the server error is name-only; arcadic only ever emits valid JSON; `Arcadic.Error`
  quarantines `detail`; the admin span is value-free).
  """
  alias Arcadic.{Admin, Conn, Identifier}

  @doc "Mint a session token from the conn's credentials (`POST /api/v1/login`)."
  @spec login(Conn.t()) :: {:ok, String.t()} | {:error, Exception.t()}
  def login(%Conn{} = conn), do: Admin.span(:login, fn -> Admin.call(conn, :login) end)

  @doc "Revoke the current session (`POST /api/v1/logout`)."
  @spec logout(Conn.t()) :: :ok | {:error, Exception.t()}
  def logout(%Conn{} = conn), do: Admin.span(:logout, fn -> Admin.call(conn, :logout) end)

  @doc "List active sessions (`GET /api/v1/sessions`). Rows carry caller-owned tokens — do not log them."
  @spec sessions(Conn.t()) :: {:ok, [map()]} | {:error, Exception.t()}
  def sessions(%Conn{} = conn),
    do: Admin.span(:sessions, fn -> Admin.result(Admin.get(conn, "/api/v1/sessions")) end)

  @doc "List server users (`GET /api/v1/server/users`)."
  @spec users(Conn.t()) :: {:ok, [map()]} | {:error, Exception.t()}
  def users(%Conn{} = conn),
    do: Admin.span(:users, fn -> Admin.result(Admin.get(conn, "/api/v1/server/users")) end)

  @doc "The server security-groups map (`GET /api/v1/server/groups`)."
  @spec groups(Conn.t()) :: {:ok, map()} | {:error, Exception.t()}
  def groups(%Conn{} = conn),
    do: Admin.span(:groups, fn -> Admin.result(Admin.get(conn, "/api/v1/server/groups")) end)

  @doc "List server API tokens (`GET /api/v1/server/api-tokens`)."
  @spec api_tokens(Conn.t()) :: {:ok, [map()]} | {:error, Exception.t()}
  def api_tokens(%Conn{} = conn),
    do:
      Admin.span(:api_tokens, fn -> Admin.result(Admin.get(conn, "/api/v1/server/api-tokens")) end)

  @doc """
  Create a server user from `%{name:, password:, databases: %{db => [roles]}}` (`databases` optional).
  `name` is `Identifier`-validated; the spec is `Jason.encode`d into the command. The password is never
  echoed (Rule 3): an unencodable spec (e.g. a non-UTF8 binary) is rejected value-free as
  `{:error, :invalid_user_spec}`. Returns `:ok` or a typed error.
  """
  @spec create_user(Conn.t(), map()) :: :ok | {:error, atom() | Exception.t()}
  def create_user(%Conn{} = conn, %{name: name, password: password} = spec)
      when is_binary(name) and is_binary(password) do
    with :ok <- Identifier.validate(name),
         {:ok, json} <- encode_user(name, password, Map.get(spec, :databases, %{})) do
      Admin.span(:create_user, fn -> Admin.to_ok(Admin.command(conn, "create user " <> json)) end)
    end
  end

  # Value-free fallback: a non-binary name/password, or a spec missing :name/:password, must NOT fall
  # through to a FunctionClauseError — its blame echoes the whole spec map (password included, a Rule-3
  # leak). Reject value-free instead, mirroring drop_user's total-on-input posture.
  def create_user(%Conn{} = _conn, _spec), do: {:error, :invalid_user_spec}

  @doc "Drop a server user. Validates `name`."
  @spec drop_user(Conn.t(), String.t()) :: :ok | {:error, atom() | Exception.t()}
  def drop_user(%Conn{} = conn, name) do
    with :ok <- Identifier.validate(name),
         do:
           Admin.span(:drop_user, fn -> Admin.to_ok(Admin.command(conn, "drop user #{name}")) end)
  end

  # Bangs
  @spec login!(Conn.t()) :: String.t()
  def login!(%Conn{} = conn), do: bang(login(conn))
  @spec logout!(Conn.t()) :: :ok
  def logout!(%Conn{} = conn), do: bang(logout(conn))
  @spec sessions!(Conn.t()) :: [map()]
  def sessions!(%Conn{} = conn), do: bang(sessions(conn))
  @spec users!(Conn.t()) :: [map()]
  def users!(%Conn{} = conn), do: bang(users(conn))
  @spec groups!(Conn.t()) :: map()
  def groups!(%Conn{} = conn), do: bang(groups(conn))
  @spec api_tokens!(Conn.t()) :: [map()]
  def api_tokens!(%Conn{} = conn), do: bang(api_tokens(conn))
  @spec create_user!(Conn.t(), map()) :: :ok
  def create_user!(%Conn{} = conn, spec), do: bang(create_user(conn, spec))
  @spec drop_user!(Conn.t(), String.t()) :: :ok
  def drop_user!(%Conn{} = conn, name), do: bang(drop_user(conn, name))

  # `Jason.encode` (NOT `encode!`): a non-UTF8 binary password passes the `is_binary` guard but makes
  # `encode!` RAISE a `Jason.EncodeError` whose message renders the raw password bytes — a Rule-3 leak.
  # Discard the error entirely and return a value-free reason; the success JSON is byte-identical.
  defp encode_user(name, password, databases) do
    case Jason.encode(%{"name" => name, "password" => password, "databases" => databases}) do
      {:ok, json} -> {:ok, json}
      {:error, _} -> {:error, :invalid_user_spec}
    end
  end

  defp bang(:ok), do: :ok
  defp bang({:ok, value}), do: value
  defp bang({:error, %{__exception__: true} = e}), do: raise(e)

  defp bang({:error, reason}),
    do: raise(ArgumentError, "security operation failed: #{inspect(reason)}")
end
