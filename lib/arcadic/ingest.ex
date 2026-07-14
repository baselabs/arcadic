defmodule Arcadic.Ingest do
  @moduledoc """
  Document bulk-insert into a target class over a transport that supports it (gRPC `BulkInsert`).

  Each row is a property map inserted into `target_class`; the result is an `InsertSummary`-shaped
  counts map `%{received, inserted, updated, ignored, failed, errors}`. This is TABLE/document ingest
  — distinct from `Arcadic.Bulk` (graph vertex/edge with `@id`/`idMapping`). gRPC-only: an HTTP/Bolt
  conn returns `:not_supported` (use `Arcadic.Bulk`, an `UNWIND $rows` statement via `Arcadic.command`,
  or `Arcadic.Import.database`).

      Arcadic.Ingest.insert(grpc_conn, "Metric", [
        %{"name" => "cpu", "value" => 0.7},
        %{"name" => "mem", "value" => 0.4}
      ])
      #=> {:ok, %{received: 2, inserted: 2, updated: 0, ignored: 0, failed: 0, errors: []}}

  ## Contract

  - **Value-free** — a row value with no gRPC representation (an integer outside int64, a non-UTF-8
    binary) yields `{:error, :invalid_record}` with NO value echoed; per-row server errors are
    surfaced as `%{row_index, code}` only (the `code` is a server enum; the raw message/field values
    are NEVER surfaced — Rule 3).
  - **Conflict handling** — `:conflict_mode` (`:error` | `:update` | `:ignore` | `:abort`, default
    server) with `:key_columns` (a list of column names) selects upsert-on-conflict behavior.
  - **In a transaction** — `BulkInsert` manages its own transaction server-side and does NOT honor an
    outer `transaction/3` (live-proven), so an ingest called inside a transaction **fails closed**
    (`:transaction_unsupported`) rather than silently auto-commit outside it. For transactional inserts
    use `Arcadic.command` with an `INSERT`/`UNWIND` statement inside the `transaction/3` block.
  - **Chunked streaming** — `:chunk_size` sends the rows via the client-streaming `InsertStream` RPC
    (`size`-sized chunks) instead of the unary `BulkInsert`; both return the same summary. (The bidi
    `InsertBidirectional` RPC with per-chunk acks is not wrapped — its flow-control/progress protocol
    has no clean mapping to this synchronous single-summary facade.)
  """
  alias Arcadic.{Conn, Error, Identifier, Opts, Telemetry}

  @insert_opts [:conflict_mode, :key_columns, :chunk_size, :timeout]

  @doc """
  Insert `rows` (property maps) into `target_class`. Returns the counts map or `{:error, …}`
  (`:invalid_record` on an unencodable value; `:invalid_identifier` on a bad class; `:not_supported`
  on a transport without document ingest).
  """
  @spec insert(Conn.t(), String.t(), [map()], keyword()) ::
          {:ok, map()} | {:error, :invalid_record | :invalid_identifier | atom() | Exception.t()}
  def insert(%Conn{} = conn, target_class, rows, opts \\ []) do
    # Value-free TOTAL guards BEFORE any coercion: a non-binary class or non-list rows must raise a
    # STATIC message, never a FunctionClauseError whose blame echoes the caller value (Rule 3).
    unless is_binary(target_class), do: raise(ArgumentError, "target_class must be a string")
    unless is_list(rows), do: raise(ArgumentError, "rows must be a list of maps")

    Opts.validate_keys!(opts, @insert_opts)

    with :ok <- validate_class(target_class) do
      Telemetry.span(:ingest, %{operation: :insert, mode: :write}, fn ->
        result = dispatch(conn, target_class, rows, opts)
        {result, stop_meta(result)}
      end)
    end
  end

  @doc "Insert `rows`, returning the counts map or raising."
  @spec insert!(Conn.t(), String.t(), [map()], keyword()) :: map()
  def insert!(%Conn{} = conn, target_class, rows, opts \\ []) do
    case insert(conn, target_class, rows, opts) do
      {:ok, summary} -> summary
      {:error, %{__exception__: true} = e} -> raise e
      {:error, reason} -> raise ArgumentError, "document ingest failed: #{inspect(reason)}"
    end
  end

  # --- private ---

  defp validate_class(class) do
    case Identifier.validate(class) do
      :ok -> :ok
      {:error, :invalid_identifier} -> {:error, :invalid_identifier}
    end
  end

  # Capability check BEFORE the empty short-circuit (consistent with Arcadic.Bulk): a transport with
  # no document-ingest callback is :not_supported regardless of payload. A supported transport + []
  # returns a zero-count success without a round-trip.
  defp dispatch(%Conn{transport: transport} = conn, target_class, rows, opts) do
    cond do
      not (Code.ensure_loaded?(transport) and function_exported?(transport, :insert_rows, 4)) ->
        {:error,
         %Error{reason: :not_supported, message: "transport does not support document ingest"}}

      rows == [] ->
        {:ok, %{received: 0, inserted: 0, updated: 0, ignored: 0, failed: 0, errors: []}}

      true ->
        transport.insert_rows(conn, target_class, rows, opts)
    end
  end

  defp stop_meta({:ok, s}) when is_map(s), do: %{reason: :ok, row_count: Map.get(s, :inserted, 0)}
  defp stop_meta({:error, %{reason: reason}}), do: %{reason: reason}
  defp stop_meta({:error, _}), do: %{reason: :error}
end
