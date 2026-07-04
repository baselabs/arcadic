defmodule Arcadic.Transport do
  @moduledoc """
  The transport seam (charter D2). One implementation ships — `Arcadic.Transport.HTTP`
  (Req/Finch). A future Bolt adapter implements the same callbacks. Callbacks are
  SEMANTIC (mode/session), not HTTP-verb-shaped, so a non-HTTP transport can honor
  them. This behaviour is also the mock seam consumed by `ash_arcadic`'s tests.

  `request` is the logical statement bundle `%{statement: String.t(), params: map(),
  language: String.t()}`; the transport shapes its own wire format from it.
  """

  alias Arcadic.{Conn, Error, TransportError}

  @type request :: %{statement: String.t(), params: map(), language: String.t()}
  @type result :: {:ok, [map()]} | {:error, Error.t() | TransportError.t()}

  @doc "Run a read (`:read` → idempotent endpoint) or write (`:write`) statement."
  @callback execute(Conn.t(), mode :: :read | :write, request(), opts :: keyword()) :: result()

  @doc "Begin a session transaction; returns the session id."
  @callback begin(Conn.t(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, Error.t() | TransportError.t()}

  @doc "Commit the session carried by `conn.session_id`."
  @callback commit(Conn.t()) :: :ok | {:error, Error.t() | TransportError.t()}

  @doc "Roll back the session carried by `conn.session_id`."
  @callback rollback(Conn.t()) :: :ok | {:error, Error.t() | TransportError.t()}

  @doc "Run a server-level admin command (create/drop database)."
  @callback server_command(Conn.t(), command :: String.t()) ::
              {:ok, map()} | {:error, Error.t() | TransportError.t()}

  @doc "List all database names (`GET /api/v1/databases`)."
  @callback list_databases(Conn.t()) ::
              {:ok, [String.t()]} | {:error, Error.t() | TransportError.t()}

  @doc "Whether a database exists."
  @callback database_exists?(Conn.t(), name :: String.t()) ::
              {:ok, boolean()} | {:error, Error.t() | TransportError.t()}

  @doc "Server readiness."
  @callback ready?(Conn.t()) :: {:ok, boolean()} | {:error, TransportError.t()}

  @optional_callbacks begin: 2,
                      commit: 1,
                      rollback: 1,
                      server_command: 2,
                      list_databases: 1,
                      database_exists?: 2,
                      ready?: 1

  @doc "Fire-and-forget write (server enqueues, does not await). Optional — HTTP implements it."
  @callback execute_async(Conn.t(), request(), opts :: keyword()) ::
              :ok | {:error, Error.t() | TransportError.t()}
  @optional_callbacks execute_async: 3

  @doc "Native fun-based transaction (for transports whose sessions are not detachable, e.g. Bolt). Optional."
  @callback transaction(Conn.t(), (Conn.t() -> result), opts :: keyword()) ::
              {:ok, result} | {:error, term()}
            when result: var
  @optional_callbacks transaction: 3

  @doc "Lazily stream a large read result as raw row maps (Bolt-only). Optional — HTTP has no cursor contract."
  @callback query_stream(Conn.t(), request(), opts :: keyword()) ::
              {:ok, Enumerable.t()} | {:error, Error.t() | TransportError.t()}
  @optional_callbacks query_stream: 3
end
