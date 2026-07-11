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

  # A RAISED Arcadic.Error is pre-commit (closure raised → tx rolled back → nothing applied): retry
  # the fuller set incl. :timeout. A RETURNED {:error, %Error{}} is a begin/commit-phase failure
  # where a commit-phase :timeout is post-commit-ambiguous → the commit set excludes it.
  @retriable_precommit [:concurrent_modification, :not_leader, :timeout]
  @retriable_commit [:concurrent_modification, :not_leader]

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
    retry = parse_retry!(opts[:retry])

    Telemetry.span(:transaction, %{isolation: opts[:isolation]}, fn ->
      result =
        if retry, do: run_with_retry(conn, fun, opts, retry, 1), else: dispatch(conn, fun, opts)

      {result, %{reason: reason_tag(result)}}
    end)
  end

  # The default (no :retry) path — byte-identical to pre-S10: Bolt native transaction/3, else the
  # HTTP session runner. Extracted so retry wraps it without perturbing the default stacktrace.
  defp dispatch(conn, fun, opts) do
    if Code.ensure_loaded?(conn.transport) and function_exported?(conn.transport, :transaction, 3),
      do: conn.transport.transaction(conn, fun, opts),
      else: run(conn, fun, opts)
  end

  # Managed retry. Each attempt runs inside ONE try/rescue (attempt_once/3) that returns a TAG; the
  # loop recurses OUTSIDE the try so a raise from a later attempt is never caught by an earlier
  # frame's rescue. A RAISED Arcadic.Error is pre-commit (the closure raised → tx rolled back →
  # nothing applied) and retries the fuller set incl. :timeout; a RETURNED {:error, %Error{}} is a
  # begin/commit-phase failure where a commit-phase :timeout is post-commit-ambiguous → the commit
  # set excludes it. On exhaustion the captured `on_exhaust` closure re-raises (raised path,
  # preserving today's reraise) or returns (returned path). A non-retriable raise propagates
  # immediately from attempt_once; rollback/2 aborts and TransportError never match the retriable sets.
  defp run_with_retry(conn, fun, opts, retry, attempt) do
    case attempt_once(conn, fun, opts) do
      {:done, result} ->
        result

      {:retriable, reason, on_exhaust} ->
        if attempt < retry.max_attempts do
          backoff(retry, attempt)
          emit_retry(attempt, reason)
          run_with_retry(conn, fun, opts, retry, attempt + 1)
        else
          on_exhaust.()
        end
    end
  end

  # Implicit try: the case is the function body; rescue catches a pre-commit raise from dispatch.
  defp attempt_once(conn, fun, opts) do
    case dispatch(conn, fun, opts) do
      {:error, %Error{reason: r}} = err when r in @retriable_commit ->
        {:retriable, r, fn -> err end}

      other ->
        {:done, other}
    end
  rescue
    e in Arcadic.Error ->
      st = __STACKTRACE__

      if e.reason in @retriable_precommit,
        do: {:retriable, e.reason, fn -> reraise e, st end},
        else: reraise(e, st)
  end

  defp emit_retry(attempt, reason),
    do: Telemetry.event([:arcadic, :transaction, :retry], %{attempt: attempt}, %{reason: reason})

  # Exponential backoff with full jitter, capped. attempt is 1-based.
  defp backoff(retry, attempt) do
    ceiling = min(retry.max_backoff_ms, retry.base_backoff_ms * Integer.pow(2, attempt - 1))
    Process.sleep(:rand.uniform(max(ceiling, 1)))
  end

  # :retry accepts nil (off), true (defaults), or a keyword; anything else is value-free-rejected.
  defp parse_retry!(nil), do: nil
  defp parse_retry!(true), do: %{max_attempts: 3, base_backoff_ms: 50, max_backoff_ms: 1000}

  defp parse_retry!(opts) when is_list(opts) do
    %{
      max_attempts: retry_pos_int!(opts, :max_attempts, 3),
      base_backoff_ms: retry_pos_int!(opts, :base_backoff_ms, 50),
      max_backoff_ms: retry_pos_int!(opts, :max_backoff_ms, 1000)
    }
  end

  defp parse_retry!(_),
    do: raise(ArgumentError, "retry must be true or a keyword list of options")

  # Each retry knob must be a positive integer. A non-integer max_attempts would defeat the
  # `attempt < max_attempts` loop bound (Elixir term ordering sorts an integer below a string, so
  # `1 < "3"` is true → unbounded retry); a non-integer backoff would crash `:rand.uniform`. Reject
  # the SHAPE value-free (echo the key + expectation, never the offending value — Rule 3).
  defp retry_pos_int!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      n when is_integer(n) and n > 0 -> n
      _ -> raise ArgumentError, "retry #{key} must be a positive integer"
    end
  end

  defp run(conn, fun, opts) do
    with {:ok, tx} <- begin_pinned(conn, [conn.base_url | conn.hosts], opts) do
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

  # Try begin against each host in order; PIN the session conn to the first host that answers
  # (the session id is host-local, so the tx must not fail over mid-flight). A begin that fails
  # with a pre-send connect error, or with a `:not_leader` REJECTION (an unambiguous 400 — no
  # session was created), rolls to the next host (D15/D16: begin iterates until it succeeds; a
  # :not_leader rejection is "safe for both modes", mirroring the data-plane `failover?/2`). Any
  # other begin error is returned (failing over would mask a genuine fault). `hosts` is cleared on
  # the pinned conn so no downstream fold re-selects mid-tx.
  defp begin_pinned(_conn, [], _opts),
    do: {:error, %TransportError{reason: :econnrefused}}

  defp begin_pinned(conn, [url | rest], opts) do
    host_conn = %{conn | base_url: url, hosts: []}

    case conn.transport.begin(host_conn, opts) do
      {:ok, session_id} ->
        {:ok, %{host_conn | session_id: session_id}}

      {:error, %TransportError{reason: reason}}
      when reason in [:econnrefused, :nxdomain] and rest != [] ->
        begin_pinned(conn, rest, opts)

      {:error, %Error{reason: :not_leader}} when rest != [] ->
        begin_pinned(conn, rest, opts)

      {:error, _} = err ->
        err
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
