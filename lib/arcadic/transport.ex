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
  @type plan_result ::
          {:ok, %{plan: String.t(), plan_tree: map(), rows: [map()]}}
          | {:error, Error.t() | TransportError.t()}

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

  @doc "Authenticated admin GET returning a decoded JSON map (HTTP-only admin surface)."
  @callback server_get(Conn.t(), path :: String.t()) ::
              {:ok, map()} | {:error, Error.t() | TransportError.t()}

  @doc "Liveness probe (`GET /api/v1/health` → 204)."
  @callback health?(Conn.t()) :: {:ok, boolean()} | {:error, TransportError.t()}

  @doc "Mint a session token from the conn's credentials (`POST /api/v1/login`)."
  @callback login(Conn.t()) :: {:ok, String.t()} | {:error, Error.t() | TransportError.t()}

  @doc "Revoke the current session (`POST /api/v1/logout`)."
  @callback logout(Conn.t()) :: :ok | {:error, Error.t() | TransportError.t()}

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
                      server_get: 2,
                      health?: 1,
                      login: 1,
                      logout: 1,
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

  @doc "Lazily stream a large read result as raw row maps (Bolt cursor, or HTTP `@rid` offset paging). Optional."
  @callback query_stream(Conn.t(), request(), opts :: keyword()) ::
              {:ok, Enumerable.t()} | {:error, Error.t() | TransportError.t()}
  @optional_callbacks query_stream: 3

  @doc """
  Run an EXPLAIN/PROFILE statement and return its plan. The `request.statement` already
  carries the `EXPLAIN `/`PROFILE ` prefix (the facade prepends it). Optional. Returns
  `%{plan: <human string>, plan_tree: <raw, transport-defined map>, rows: <executed rows>}`.
  """
  @callback explain(Conn.t(), request(), opts :: keyword()) :: plan_result()
  @optional_callbacks explain: 3

  @doc """
  Bulk-ingest NDJSON vertex/edge records (`POST /api/v1/batch/<db>`). The body is already-serialized
  NDJSON iodata; `opts` carries the query params (`:light_edges`, `:commit_every`). Edge endpoints
  resolve by the vertex `@id` temp key in the body, not a query param.
  Optional — HTTP implements it; Bolt has no batch endpoint. Returns the parsed
  `{verticesCreated, edgesCreated, elapsedMs, idMapping}` map.
  """
  @callback batch_ingest(Conn.t(), ndjson :: iodata(), opts :: keyword()) ::
              {:ok, map()} | {:error, Error.t() | TransportError.t()}
  @optional_callbacks batch_ingest: 3
end
