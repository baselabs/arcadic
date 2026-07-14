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
  Like `execute/4` for a read/write but also returns the server's HA commit index
  (`X-ArcadeDB-Commit-Index` response header) as `{:ok, rows, index}` — `index` is
  `nil` on a single (non-HA) server where the header is absent. Optional — HTTP
  implements it; Bolt has no HA header. Used by `query_bookmarked`/`command_bookmarked`.
  """
  @callback execute_with_index(Conn.t(), mode :: :read | :write, request(), opts :: keyword()) ::
              {:ok, [map()], integer() | nil} | {:error, Error.t() | TransportError.t()}
  @optional_callbacks execute_with_index: 4

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

  @doc """
  Bulk-insert `rows` (property maps) into `target_class` — document/table ingest (gRPC `BulkInsert`),
  distinct from `batch_ingest`'s graph vertex/edge batch. `opts` carries `:conflict_mode`/`:key_columns`.
  Returns the `InsertSummary`-shaped counts map (per-row errors surfaced value-free as `%{row_index, code}`).
  Optional — gRPC implements it; HTTP/Bolt do not.
  """
  @callback insert_rows(Conn.t(), target_class :: String.t(), rows :: [map()], opts :: keyword()) ::
              {:ok, map()} | {:error, Error.t() | TransportError.t()}
  @optional_callbacks insert_rows: 4

  @doc """
  Write raw InfluxDB line protocol to `POST /api/v1/ts/<db>/write` (204 on success). `lines` is
  already-built line-protocol iodata; `opts[:precision]` is the validated `"ns"|"us"|"ms"|"s"`
  string (the FACADE validates — an invalid value is silently ignored server-side, probed 26.7.2).
  Append-only, no dedup: a lost response + naive retry duplicates every point. Optional — HTTP-only.
  """
  @callback ts_write(Conn.t(), lines :: iodata(), opts :: keyword()) ::
              :ok | {:error, Error.t() | TransportError.t()}
  @optional_callbacks ts_write: 3

  @doc """
  Run a time-series query (`POST /api/v1/ts/<db>/query`). `body` is the already-shaped wire map.
  Returns the RAW `%{columns, rows, count}` or AGGREGATED `%{aggregations, buckets, count}` shape
  (atomized top-level keys; bucket maps atomized to `%{timestamp, values}`). Optional — HTTP-only.
  """
  @callback ts_query(Conn.t(), body :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, Error.t() | TransportError.t()}
  @optional_callbacks ts_query: 3

  @doc """
  Fetch the newest point (`GET /api/v1/ts/<db>/latest`). `params` is a `[{String.t(), String.t()}]`
  query-param list (`type` required; at most one `tag` — the server applies only the FIRST, probed).
  Returns `%{columns, latest}` (atomized). Optional — HTTP-only.
  """
  @callback ts_latest(Conn.t(), params :: [{String.t(), String.t()}], opts :: keyword()) ::
              {:ok, map()} | {:error, Error.t() | TransportError.t()}
  @optional_callbacks ts_latest: 3

  @doc """
  PromQL read family (`GET /api/v1/ts/<db>/prom/api/v1/…`). `op` is the allowlisted route atom —
  `:query | :query_range | :labels | :series | {:label_values, label}` (the label is
  facade-validated AND URL-encoded here). Unwraps the Prometheus envelope: `status:"success"` →
  `{:ok, data}`; `status:"error"` → a typed error. Optional — HTTP-only.
  """
  @callback ts_prom_get(
              Conn.t(),
              op :: atom() | {:label_values, String.t()},
              params :: [{String.t(), String.t()}],
              opts :: keyword()
            ) :: {:ok, map() | list()} | {:error, Error.t() | TransportError.t()}
  @optional_callbacks ts_prom_get: 4
end
