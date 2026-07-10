defmodule Arcadic.Bulk do
  @moduledoc """
  Bulk-create vertices and edges over ArcadeDB's `POST /api/v1/batch/<db>` NDJSON endpoint —
  the heavy-ingest sibling of `Arcadic.Import.database`, for records you hold in the client.

  Each record is a caller map with ArcadeDB's structural keys — `"@type" => "vertex" | "edge"`,
  `"@class" => <TypeName>`, arbitrary properties, and (edges) `"@from"`/`"@to"` referencing the
  vertices' id-property values. Vertices must appear before the edges that reference them; pass
  `id_property:` to resolve edge endpoints. Records are serialized to NDJSON and sent as one POST;
  the batch is **structured record ingest, not statement text, so it is injection-inert** (a value
  is stored verbatim). Tenant-blind, HTTP-only.

      Arcadic.Bulk.ingest(conn, [
        %{"@type" => "vertex", "@class" => "Person", "id" => 1, "name" => "Alice"},
        %{"@type" => "vertex", "@class" => "Person", "id" => 2, "name" => "Bob"},
        %{"@type" => "edge", "@class" => "Knows", "@from" => 1, "@to" => 2}
      ], id_property: "id")
      #=> {:ok, %{vertices_created: 2, edges_created: 1, elapsed_ms: 7}}

  ## Operational contract (read before relying on it)

  - **Atomic by default** — any bad line rolls back the whole batch. Passing `:commit_every`
    **forfeits that guarantee**: a fault after a commit boundary leaves a committed prefix.
  - **Create-only, not upsert** — records are always created (no dedup; `:id_property` resolves
    edge endpoints, it does not dedupe vertices). A lost response then a naive retry **duplicates**
    every vertex (the same non-confirmability class as `Arcadic.command_async/4`). For idempotent
    bulk-upsert use the `UNWIND $rows` idiom over `Arcadic.command/4` (see usage-rules "Bulk loading").
  - **One in-memory POST** — the whole NDJSON body is held and sent at once, against one receive
    timeout. For a very large or streamed load, prefer `Arcadic.Import.database` (server-side fetch).
  - **Line errors are reachable** — a failed line's `%Arcadic.Error{}.detail` (quarantined from
    `message/1`/`inspect/1` but reachable via `error.detail`) may contain the rejected record
    fragment (caller data — assume PII); redact before logging.
  """
  alias Arcadic.{Conn, Error, Identifier, Opts, Telemetry}

  @ingest_opts [:id_property, :light_edges, :commit_every, :timeout]

  @doc """
  Bulk-create `records` (a list of caller vertex/edge maps). `opts`: `:id_property`
  (identifier-validated), `:light_edges` (bool), `:commit_every` (pos_integer), `:timeout` (ms).
  Returns `{:ok, %{vertices_created, edges_created, elapsed_ms}}` or `{:error, …}` (`:invalid_record`
  on an unencodable record; `:not_supported` on a transport with no batch endpoint; else an
  `Arcadic.Error`/`Arcadic.TransportError`).
  """
  @spec ingest(Conn.t(), [map()], keyword()) ::
          {:ok,
           %{
             vertices_created: non_neg_integer(),
             edges_created: non_neg_integer(),
             elapsed_ms: non_neg_integer()
           }}
          | {:error, :invalid_record | atom() | Exception.t()}
  def ingest(%Conn{} = conn, records, opts \\ []) do
    # Value-free list-ness guard BEFORE any other work: a bare `when is_list(records)` head-guard
    # has no total fallback, so a non-list `records` (e.g. a single map) matches no clause and the
    # FunctionClauseError blame ECHOES the record verbatim (Rule 3 — the moduledoc marks records PII).
    unless is_list(records) do
      raise ArgumentError, "records must be a list of maps"
    end

    Opts.validate_keys!(opts, @ingest_opts)
    validate_id_property!(opts)

    with {:ok, ndjson} <- encode_ndjson(records) do
      Telemetry.span(:bulk, %{operation: :ingest, mode: :write}, fn ->
        result = dispatch(conn, ndjson, opts)
        {shape(result), stop_meta(result)}
      end)
    end
  end

  @doc "Bulk-create `records`, returning the counts map or raising."
  @spec ingest!(Conn.t(), [map()], keyword()) :: map()
  def ingest!(%Conn{} = conn, records, opts \\ []) do
    case ingest(conn, records, opts) do
      {:ok, counts} -> counts
      {:error, %{__exception__: true} = e} -> raise e
      {:error, reason} -> raise ArgumentError, "bulk ingest failed: #{inspect(reason)}"
    end
  end

  # --- private ---

  defp encode_ndjson(records) do
    records
    |> Enum.reduce_while({:ok, []}, &reduce_record/2)
    |> case do
      {:ok, lines} -> {:ok, Enum.reverse(lines)}
      {:error, :invalid_record} -> {:error, :invalid_record}
      {:raise, msg} -> raise ArgumentError, msg
    end
  end

  # A non-map record malforms the NDJSON → raise a STATIC message (never the record). A map is
  # encoded with the NON-bang Jason.encode/1 so an unencodable value (a non-UTF-8 binary) yields
  # {:error, :invalid_record}, never a Jason.encode! raise that would echo the offending bytes (Rule 3).
  defp reduce_record(record, {:ok, acc}) when is_map(record) do
    case Jason.encode(record) do
      {:ok, line} -> {:cont, {:ok, [[line, "\n"] | acc]}}
      {:error, _} -> {:halt, {:error, :invalid_record}}
    end
  end

  defp reduce_record(_record, {:ok, _acc}),
    do: {:halt, {:raise, "each bulk record must be a map"}}

  # An empty batch never hits the wire — POSTing empty NDJSON is a pointless round-trip. Return the
  # zero-count success the endpoint would produce for no work; it flows through shape/stop_meta so the
  # span still fires (row_count: 0). `ndjson == []` iff `records == []` (any record yields a non-empty
  # line), so matching the encoded form here needs no extra flag.
  defp dispatch(_conn, [], _opts), do: {:ok, %{}}

  defp dispatch(%Conn{transport: transport} = conn, ndjson, opts) do
    if Code.ensure_loaded?(transport) and function_exported?(transport, :batch_ingest, 3) do
      transport.batch_ingest(conn, ndjson, opts)
    else
      {:error, %Error{reason: :not_supported, message: "transport does not support bulk ingest"}}
    end
  end

  defp shape({:ok, body}) when is_map(body) do
    {:ok,
     %{
       vertices_created: Map.get(body, "verticesCreated", 0),
       edges_created: Map.get(body, "edgesCreated", 0),
       elapsed_ms: Map.get(body, "elapsedMs", 0)
     }}
  end

  # The batch endpoint contract is a counts OBJECT; `Transport.HTTP.unwrap_body/1` returns {:ok, body}
  # for ANY 2xx body (no is_map guard), so a non-map 2xx (empty/list/scalar) is genuinely off-contract
  # — a total fallback returns a typed error instead of a FunctionClauseError inside the span callback.
  defp shape({:ok, _}), do: {:error, :unexpected_response}
  defp shape({:error, _} = err), do: err

  defp stop_meta({:ok, body}) when is_map(body),
    do: %{
      reason: :ok,
      row_count: Map.get(body, "verticesCreated", 0) + Map.get(body, "edgesCreated", 0)
    }

  defp stop_meta({:ok, _}), do: %{reason: :unexpected_response}
  defp stop_meta({:error, %{reason: reason}}), do: %{reason: reason}
  defp stop_meta({:error, _}), do: %{reason: :error}

  defp validate_id_property!(opts) do
    case Keyword.fetch(opts, :id_property) do
      :error ->
        :ok

      {:ok, prop} ->
        case Identifier.validate(prop) do
          :ok ->
            :ok

          {:error, :invalid_identifier} ->
            raise ArgumentError, "id_property must be a valid identifier"
        end
    end
  end
end
