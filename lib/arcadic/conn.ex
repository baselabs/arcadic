defmodule Arcadic.Conn do
  @moduledoc """
  Connection handle for ArcadeDB — pure data, no process.

  HTTP has no per-connection state; Finch owns the socket pool and the ArcadeDB
  session (when inside a transaction) rides `session_id`. Build one with
  `Arcadic.connect/3`; derive a same-pool handle on another database with
  `with_database/2`.
  """

  alias Arcadic.{Identifier, Opts}

  @type consistency :: :eventual | :read_your_writes | :linearizable

  @type t :: %__MODULE__{
          base_url: String.t(),
          database: String.t(),
          auth: {String.t(), String.t()} | {:bearer, String.t()},
          session_id: String.t() | nil,
          transport: module(),
          transport_options: keyword(),
          timeout: pos_integer() | nil,
          consistency: consistency(),
          read_after: integer() | nil,
          hosts: [String.t()]
        }

  @enforce_keys [:base_url, :database, :auth]
  defstruct [
    :base_url,
    :database,
    :auth,
    :session_id,
    :timeout,
    :read_after,
    transport: Arcadic.Transport.HTTP,
    transport_options: [],
    consistency: :eventual,
    hosts: []
  ]

  @consistency_levels [:eventual, :read_your_writes, :linearizable]

  # Value-free opt-key allowlist (mirrors the query/command surface via Arcadic.Opts.validate_keys!/2).
  # An unknown key is a caller TYPO (e.g. `consistancy:`/`hosts` mis-spelled) that would otherwise be
  # silently ignored — for a connection-control opt that means the wrong default silently applies.
  @connect_opts [:auth, :transport, :transport_options, :timeout, :consistency, :hosts]

  @doc """
  Build a connection handle.

  ## Options
    * `:auth` — `{user, pass}`. REQUIRED (no default credential).
    * `:transport` — transport module (default `Arcadic.Transport.HTTP`).
    * `:transport_options` — keyword passed to the transport (`:finch`, `:plug`, `:timeout`, pool knobs).
    * `:timeout` — default per-call receive timeout (ms).
    * `:consistency` - read-consistency level: `:eventual` (default) | `:read_your_writes` |
      `:linearizable`. HTTP-only; a non-default level on a Bolt conn raises.
    * `:hosts` - additional `http(s)` base URLs for multi-host availability failover
      (default `[]`). HTTP-only; a non-empty list on a Bolt conn raises.

  ## Examples

      iex> Arcadic.connect("http://localhost:2480", "mydb", auth: {"root", "x"}).database
      "mydb"

  """
  @spec new(String.t(), String.t(), keyword()) :: t()
  def new(base_url, database, opts \\ []) when is_binary(base_url) and is_binary(database) do
    Opts.validate_keys!(opts, @connect_opts)
    auth = opts[:auth] || raise ArgumentError, "Arcadic.connect/3 requires :auth {user, pass}"
    transport = Keyword.get(opts, :transport, Arcadic.Transport.HTTP)
    validate_identifier!(database)
    validate_auth!(auth, transport)

    consistency = Keyword.get(opts, :consistency, :eventual)
    hosts = Keyword.get(opts, :hosts, [])
    validate_consistency!(consistency, transport)
    validate_hosts!(hosts, transport)

    %__MODULE__{
      base_url: String.trim_trailing(base_url, "/"),
      database: database,
      auth: auth,
      session_id: nil,
      transport: transport,
      transport_options: Keyword.get(opts, :transport_options, []),
      timeout: Keyword.get(opts, :timeout),
      consistency: consistency,
      read_after: nil,
      hosts: Enum.map(hosts, &String.trim_trailing(&1, "/"))
    }
  end

  @doc "Derive a same-pool handle on another database; validates and clears the session."
  @spec with_database(t(), String.t()) :: t()
  def with_database(%__MODULE__{} = conn, database) when is_binary(database) do
    validate_identifier!(database)
    %{conn | database: database, session_id: nil}
  end

  @doc "Derive a Bearer-auth handle from a Basic one (typically after `Arcadic.Security.login/1`)."
  @spec with_bearer(t(), String.t()) :: t()
  def with_bearer(%__MODULE__{transport: Arcadic.Transport.Bolt}, _token),
    do: raise(ArgumentError, "bearer auth requires the HTTP transport")

  def with_bearer(%__MODULE__{} = conn, token) when is_binary(token),
    do: %{conn | auth: {:bearer, token}, session_id: nil}

  # A non-binary token would otherwise FunctionClauseError, echoing the token in the blame (Rule 3).
  def with_bearer(%__MODULE__{}, _token),
    do: raise(ArgumentError, "bearer token must be a string")

  @doc "Derive a handle with a read-consistency level; validates and clears the session. HTTP-only."
  @spec with_consistency(t(), consistency()) :: t()
  def with_consistency(%__MODULE__{transport: Arcadic.Transport.Bolt}, level)
      when level != :eventual,
      do: raise(ArgumentError, "read-consistency requires the HTTP transport")

  def with_consistency(%__MODULE__{} = conn, level) do
    validate_consistency!(level, conn.transport)
    %{conn | consistency: level, session_id: nil}
  end

  defp validate_identifier!(database) do
    case Identifier.validate(database) do
      :ok -> :ok
      {:error, :invalid_identifier} -> raise ArgumentError, "invalid database identifier"
    end
  end

  # Bolt authenticates from transport_options (:username/:password), never conn.auth, so a
  # {:bearer, _} conn on Bolt would silently ignore the token — reject value-free at construction.
  defp validate_auth!({:bearer, _}, Arcadic.Transport.Bolt),
    do: raise(ArgumentError, "bearer auth requires the HTTP transport")

  defp validate_auth!(_auth, _transport), do: :ok

  # Consistency is an HTTP request header; a non-default level on Bolt would be a silent
  # no-op, so reject it value-free (mirrors with_bearer/2's Bolt rejection). Echo the
  # allowed set, never the offending value (Rule 3).
  defp validate_consistency!(:eventual, _transport), do: :ok

  defp validate_consistency!(level, Arcadic.Transport.Bolt) when level in @consistency_levels,
    do: raise(ArgumentError, "read-consistency requires the HTTP transport")

  defp validate_consistency!(level, _transport) when level in @consistency_levels, do: :ok

  defp validate_consistency!(_level, _transport),
    do:
      raise(
        ArgumentError,
        "unknown consistency; allowed: #{inspect(@consistency_levels)}"
      )

  # hosts are additional base URLs the failover fold replays the conn's credential to,
  # so they must be same-trust http(s) replicas — validate the SHAPE value-free at
  # construction (never echo the value). Multi-host is HTTP-only.
  defp validate_hosts!([], _transport), do: :ok

  defp validate_hosts!(_hosts, Arcadic.Transport.Bolt),
    do: raise(ArgumentError, "multi-host failover requires the HTTP transport")

  defp validate_hosts!(hosts, _transport) when is_list(hosts) do
    Enum.each(hosts, &validate_host_url!/1)
  end

  defp validate_hosts!(_hosts, _transport),
    do: raise(ArgumentError, "hosts must be a list of http(s) base URLs")

  defp validate_host_url!(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: s, host: h}} when s in ["http", "https"] and is_binary(h) and h != "" ->
        :ok

      _ ->
        raise ArgumentError, "each host must be an http(s) base URL"
    end
  end

  defp validate_host_url!(_), do: raise(ArgumentError, "each host must be an http(s) base URL")

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(conn, opts) do
      concat([
        "#Arcadic.Conn<",
        to_doc(
          %{
            base_url: conn.base_url,
            database: conn.database,
            auth: "[REDACTED]",
            session_id: if(conn.session_id, do: "[REDACTED]", else: nil),
            transport: conn.transport
          },
          opts
        ),
        ">"
      ])
    end
  end
end
