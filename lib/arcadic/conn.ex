defmodule Arcadic.Conn do
  @moduledoc """
  Connection handle for ArcadeDB — pure data, no process.

  HTTP has no per-connection state; Finch owns the socket pool and the ArcadeDB
  session (when inside a transaction) rides `session_id`. Build one with
  `Arcadic.connect/3`; derive a same-pool handle on another database with
  `with_database/2`.
  """

  alias Arcadic.Identifier

  @type t :: %__MODULE__{
          base_url: String.t(),
          database: String.t(),
          auth: {String.t(), String.t()} | {:bearer, String.t()},
          session_id: String.t() | nil,
          transport: module(),
          transport_options: keyword(),
          timeout: pos_integer() | nil
        }

  @enforce_keys [:base_url, :database, :auth]
  defstruct [
    :base_url,
    :database,
    :auth,
    :session_id,
    :timeout,
    transport: Arcadic.Transport.HTTP,
    transport_options: []
  ]

  @doc """
  Build a connection handle.

  ## Options
    * `:auth` — `{user, pass}`. REQUIRED (no default credential).
    * `:transport` — transport module (default `Arcadic.Transport.HTTP`).
    * `:transport_options` — keyword passed to the transport (`:finch`, `:plug`, `:timeout`, pool knobs).
    * `:timeout` — default per-call receive timeout (ms).

  ## Examples

      iex> Arcadic.connect("http://localhost:2480", "mydb", auth: {"root", "x"}).database
      "mydb"

  """
  @spec new(String.t(), String.t(), keyword()) :: t()
  def new(base_url, database, opts \\ []) when is_binary(base_url) and is_binary(database) do
    auth = opts[:auth] || raise ArgumentError, "Arcadic.connect/3 requires :auth {user, pass}"
    transport = Keyword.get(opts, :transport, Arcadic.Transport.HTTP)
    validate_identifier!(database)
    validate_auth!(auth, transport)

    %__MODULE__{
      base_url: String.trim_trailing(base_url, "/"),
      database: database,
      auth: auth,
      session_id: nil,
      transport: transport,
      transport_options: Keyword.get(opts, :transport_options, []),
      timeout: Keyword.get(opts, :timeout)
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
