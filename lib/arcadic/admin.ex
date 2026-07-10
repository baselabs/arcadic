defmodule Arcadic.Admin do
  @moduledoc false
  # Shared, tenant-blind plumbing for the HTTP-only admin surface: a value-free [:arcadic, :admin]
  # span, function_exported?-guarded passthrough to the optional transport callbacks (→ :not_supported
  # on Bolt/a mock, never UndefinedFunctionError), and a SQL-admin path. One audited copy of the
  # guard + span, per the Arcadic.Opts shared-internal precedent.
  alias Arcadic.{Conn, Error, Telemetry}

  @doc "Run `fun` (returns :ok | {:ok,_} | {:error,_}) inside a value-free [:arcadic, :admin] span."
  @spec span(atom(), (-> term())) :: :ok | {:ok, term()} | {:error, term()}
  def span(operation, fun) when is_atom(operation) and is_function(fun, 0) do
    Telemetry.span(:admin, %{operation: operation}, fn ->
      case fun.() do
        :ok -> {:ok, %{reason: :ok}}
        {:ok, _} = ok -> {ok, %{reason: :ok}}
        {:error, err} = error -> {error, %{reason: reason_of(err)}}
        # Value-free catch-all: an off-contract thunk return would otherwise CaseClauseError, echoing
        # the offending value (a Rule-3 leak if it carries caller data). Raise value-free instead.
        _other -> raise ArgumentError, "admin operation returned an unexpected result shape"
      end
    end)
  end

  @doc "Guarded authenticated admin GET (optional `server_get/2` callback)."
  @spec get(Conn.t(), String.t()) :: {:ok, map()} | {:error, Exception.t()}
  def get(%Conn{} = conn, path),
    do: guard(conn, :server_get, 2, fn -> conn.transport.server_get(conn, path) end)

  @doc "Guarded server command (optional `server_command/2` callback)."
  @spec command(Conn.t(), String.t()) :: {:ok, map()} | {:error, Exception.t()}
  def command(%Conn{} = conn, cmd),
    do: guard(conn, :server_command, 2, fn -> conn.transport.server_command(conn, cmd) end)

  @doc "Guarded 0/1-arity admin callback (health?/login/logout)."
  @spec call(Conn.t(), atom()) :: term()
  def call(%Conn{} = conn, fun),
    do: guard(conn, fun, 1, fn -> apply(conn.transport, fun, [conn]) end)

  @doc "Run a fixed SQL admin statement over the required `execute/4` callback (no params, write mode)."
  @spec sql(Conn.t(), String.t()) :: {:ok, [map()]} | {:error, Exception.t()}
  def sql(%Conn{} = conn, statement) do
    conn.transport.execute(
      conn,
      :write,
      %{statement: statement, params: %{}, language: "sql"},
      []
    )
  end

  @doc "Normalize an :ok | {:ok,_} | {:error,_} command result to :ok | {:error,_}."
  @spec to_ok(term()) :: :ok | {:error, term()}
  def to_ok(:ok), do: :ok
  def to_ok({:ok, _}), do: :ok
  def to_ok({:error, _} = e), do: e
  # Value-free catch-all (Rule 3): never FunctionClauseError-echo an off-contract result.
  def to_ok(_other), do: raise(ArgumentError, "admin command returned an unexpected result shape")

  @doc "Extract a nested \"result\" from a server body; pass the whole body/error through otherwise."
  @spec result({:ok, map()} | {:error, term()}) :: {:ok, term()} | {:error, term()}
  def result({:ok, %{"result" => r}}), do: {:ok, r}
  def result({:ok, body}), do: {:ok, body}
  def result({:error, _} = e), do: e

  # A transport (Bolt/mock) lacking an OPTIONAL admin callback → typed :not_supported.
  defp guard(conn, fun, arity, thunk) do
    if Code.ensure_loaded?(conn.transport) and function_exported?(conn.transport, fun, arity) do
      thunk.()
    else
      {:error, %Error{reason: :not_supported, message: "transport does not support #{fun}"}}
    end
  end

  defp reason_of(%{reason: reason}), do: reason
  defp reason_of(_), do: :error
end
