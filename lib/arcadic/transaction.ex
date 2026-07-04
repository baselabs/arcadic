defmodule Arcadic.Transaction do
  @moduledoc """
  Session transactions. `transaction/3` begins a session, runs the fun with a
  session-scoped conn, and commits on a normal return. On an exception it rolls
  back and RERAISES (postgrex semantics — unexpected failures propagate, they do
  not become `{:error, …}`). Use `rollback/2` for an intentional abort that yields
  `{:error, reason}`. Nesting raises — there is no verified HTTP savepoint contract.
  """

  alias Arcadic.{Conn, Error, Telemetry, TransportError}

  require Logger

  @rollback_throw :arcadic_rollback

  @doc "Run `fun` inside a session transaction. Opts: `:isolation` (`:read_committed` | `:repeatable_read`)."
  @spec transaction(Conn.t(), (Conn.t() -> result), keyword()) ::
          {:ok, result} | {:error, Error.t() | TransportError.t() | term()}
        when result: var
  # Function head declares the default; the clauses below must NOT repeat `\\`
  # (multiple clauses + a per-clause default is a compile warning → gate failure).
  def transaction(conn, fun, opts \\ [])

  def transaction(%Conn{session_id: sid}, _fun, _opts) when is_binary(sid) do
    raise ArgumentError, "nested transactions are not supported (no HTTP savepoint contract)"
  end

  def transaction(%Conn{} = conn, fun, opts) when is_function(fun, 1) do
    Telemetry.span(:transaction, %{isolation: opts[:isolation]}, fn ->
      result =
        if Code.ensure_loaded?(conn.transport) and
             function_exported?(conn.transport, :transaction, 3) do
          conn.transport.transaction(conn, fun, opts)
        else
          run(conn, fun, opts)
        end

      {result, %{reason: reason_tag(result)}}
    end)
  end

  defp run(conn, fun, opts) do
    with {:ok, session_id} <- conn.transport.begin(conn, opts) do
      tx = %{conn | session_id: session_id}

      try do
        result = fun.(tx)

        case conn.transport.commit(tx) do
          :ok -> {:ok, result}
          {:error, error} -> {:error, error}
        end
      rescue
        exception ->
          _ = safe_rollback(tx)
          reraise(exception, __STACKTRACE__)
      catch
        :throw, {@rollback_throw, reason} ->
          _ = safe_rollback(tx)
          {:error, reason}

        # Any other non-local exit (a bare throw or an exit) must still roll the
        # session back before it propagates — otherwise the transaction leaks open.
        kind, value when kind in [:throw, :exit] ->
          _ = safe_rollback(tx)
          :erlang.raise(kind, value, __STACKTRACE__)
      end
    end
  end

  defp reason_tag({:ok, _}), do: :commit
  defp reason_tag({:error, _}), do: :rollback

  @doc "Abort the current transaction with `reason`; the enclosing `transaction/3` returns `{:error, reason}`."
  @spec rollback(Conn.t(), term()) :: no_return()
  def rollback(%Conn{}, reason), do: throw({@rollback_throw, reason})

  @doc "Begin a session; returns a session-scoped conn."
  @spec begin(Conn.t(), keyword()) :: {:ok, Conn.t()} | {:error, Error.t() | TransportError.t()}
  def begin(conn, opts \\ [])

  # A conn already carrying a session must not open a nested one (mirrors the
  # transaction/3 nested guard; low-level begin/2 returns a tagged error).
  def begin(%Conn{session_id: sid}, _opts) when is_binary(sid) do
    {:error, %Error{reason: :transaction_error, message: "already in a session"}}
  end

  def begin(%Conn{} = conn, opts) do
    with {:ok, session_id} <- conn.transport.begin(conn, opts),
         do: {:ok, %{conn | session_id: session_id}}
  end

  @doc "Commit a session-scoped conn."
  @spec commit(Conn.t()) :: :ok | {:error, Error.t() | TransportError.t()}
  def commit(%Conn{session_id: nil}),
    do: {:error, %Error{reason: :transaction_error, message: "no active session"}}

  def commit(%Conn{} = conn), do: conn.transport.commit(conn)

  @doc "Roll back a session-scoped conn."
  @spec rollback(Conn.t()) :: :ok | {:error, Error.t() | TransportError.t()}
  def rollback(%Conn{session_id: nil}), do: :ok
  def rollback(%Conn{} = conn), do: conn.transport.rollback(conn)

  # Rollback during unwinding must never mask the original failure.
  defp safe_rollback(tx) do
    case conn_rollback(tx) do
      :ok ->
        :ok

      {:error, error} ->
        Logger.warning("arcadic: rollback failed during unwind: #{inspect(error.__struct__)}")
    end
  end

  defp conn_rollback(%Conn{} = tx), do: tx.transport.rollback(tx)
end
