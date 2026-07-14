defmodule Arcadic.Record do
  @moduledoc """
  Single-record CRUD over gRPC — create/lookup/update/delete a record by its `@rid`, working in
  **raw maps** (no typed Node/Edge decode; that stays `ash_arcadic`'s job — charter-compatible).
  A convenience surface over the gRPC `CreateRecord`/`LookupByRid`/`UpdateRecord`/`DeleteRecord`
  RPCs; everything here is also reachable via `Arcadic.command`/`query` with SQL/Cypher. gRPC-only:
  an HTTP/Bolt conn returns `:not_supported`.

      {:ok, rid} = Arcadic.Record.create(grpc_conn, "Person", %{"name" => "Ada"})
      {:ok, %{"name" => "Ada", "@rid" => ^rid}} = Arcadic.Record.lookup(grpc_conn, rid)
      :ok = Arcadic.Record.update(grpc_conn, rid, %{"age" => 36})
      :ok = Arcadic.Record.delete(grpc_conn, rid)

  Values are encoded value-free (an unencodable value → `{:error, :invalid_record}`, no echo).
  `update/4` merges properties by default (partial update); `replace: true` replaces the record.
  """
  alias Arcadic.{Conn, Error, Telemetry}

  @doc "Create a record of `type` from a property map. Returns `{:ok, rid}`."
  @spec create(Conn.t(), String.t(), map(), keyword()) ::
          {:ok, String.t()} | {:error, atom() | Exception.t()}
  def create(%Conn{} = conn, type, props, opts \\ []) do
    unless is_binary(type), do: raise(ArgumentError, "type must be a string")
    unless is_map(props), do: raise(ArgumentError, "props must be a map")

    call(conn, :create_record, [conn, type, props, opts], :create)
  end

  @doc "Look up a record by `rid`. Returns `{:ok, map}` (with `@rid`/`@type`), or `{:ok, nil}` if absent."
  @spec lookup(Conn.t(), String.t(), keyword()) ::
          {:ok, map() | nil} | {:error, atom() | Exception.t()}
  def lookup(%Conn{} = conn, rid, opts \\ []) do
    unless is_binary(rid), do: raise(ArgumentError, "rid must be a string")
    call(conn, :lookup_record, [conn, rid, opts], :lookup)
  end

  @doc "Update a record by `rid`. Merges `props` (partial); `replace: true` replaces the record. Returns `:ok`."
  @spec update(Conn.t(), String.t(), map(), keyword()) :: :ok | {:error, atom() | Exception.t()}
  def update(%Conn{} = conn, rid, props, opts \\ []) do
    unless is_binary(rid), do: raise(ArgumentError, "rid must be a string")
    unless is_map(props), do: raise(ArgumentError, "props must be a map")

    call(conn, :update_record, [conn, rid, props, opts], :update)
  end

  @doc "Delete a record by `rid`. Returns `:ok`."
  @spec delete(Conn.t(), String.t(), keyword()) :: :ok | {:error, atom() | Exception.t()}
  def delete(%Conn{} = conn, rid, opts \\ []) do
    unless is_binary(rid), do: raise(ArgumentError, "rid must be a string")
    call(conn, :delete_record, [conn, rid, opts], :delete)
  end

  # --- private ---

  # function_exported?-guard (like Arcadic.Bulk/Ingest): a transport without the record callback
  # returns :not_supported, never UndefinedFunctionError. The arity is the callback's args length.
  defp call(%Conn{transport: transport} = _conn, fun, args, span_op) do
    if Code.ensure_loaded?(transport) and function_exported?(transport, fun, length(args)) do
      Telemetry.span(:record, %{operation: span_op, mode: :write}, fn ->
        result = apply(transport, fun, args)
        {result, %{reason: reason_tag(result)}}
      end)
    else
      {:error, %Error{reason: :not_supported, message: "transport does not support record CRUD"}}
    end
  end

  defp reason_tag(:ok), do: :ok
  defp reason_tag({:ok, _}), do: :ok
  defp reason_tag({:error, %{reason: r}}), do: r
  defp reason_tag({:error, _}), do: :error
end
