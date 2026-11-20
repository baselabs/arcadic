if Code.ensure_loaded?(DBConnection) do
  defmodule Arcadic.Transport.Bolt.Connection do
    @moduledoc false
    use DBConnection

    alias Arcadic.{Error, TransportError}
    alias Arcadic.Transport.Bolt
    alias Arcadic.Transport.Bolt.{Client, Response}

    @impl true
    def connect(opts) do
      case Bolt.leak_safe_connect(opts) do
        {:ok, state} -> {:ok, state}
        {:error, e} -> {:error, Bolt.stream_error(e)}
      end
    end

    @impl true
    def disconnect(_, %{client: client}) do
      try do
        Client.goodbye(client)
      after
        Client.close(client)
      end

      :ok
    end

    @impl true
    def checkout(state), do: {:ok, state}

    @impl true
    def ping(state) do
      case Client.request(state.client, :reset, [], 5000) do
        {:ok, _} -> {:ok, %{state | status: :idle, cursor_open?: false}}
        {:error, e} -> disconnect_result(e, state)
      end
    end

    @impl true
    def handle_begin(opts, %{status: :idle} = state),
      do: control(:begin, [Keyword.get(opts, :extra_parameters, %{})], :transaction, opts, state)

    def handle_begin(_, state), do: {state.status, state}

    @impl true
    def handle_commit(opts, %{status: :transaction} = state),
      do: control(:commit, [], :idle, opts, state)

    def handle_commit(_, state), do: {state.status, state}

    @impl true
    def handle_rollback(opts, %{status: :transaction} = state),
      do: control(:rollback, [], :idle, opts, state)

    def handle_rollback(_, state), do: {state.status, state}

    defp control(name, fields, status, opts, state) do
      case Client.request(state.client, name, fields, timeout(opts)) do
        {:ok, meta} -> {:ok, meta, %{state | status: status, cursor_open?: false}}
        {:error, e} -> disconnect_result(e, state)
      end
    end

    @impl true
    def handle_status(_, state), do: {state.status, state}

    @impl true
    def handle_prepare(query, _, state), do: {:ok, query, state}

    @impl true
    def handle_close(_, _, state), do: {:ok, :ok, state}

    @impl true
    def handle_execute(_, _, _, %{cursor_open?: true} = state),
      do: {:error, %TransportError{reason: :cursor_open}, state}

    def handle_execute(query, params, opts, state) do
      with {:ok, run} <-
             Bolt.stream_run(
               state.client,
               Bolt.statement_of(query),
               params,
               query.extra,
               timeout(opts)
             ),
           {:ok, pull} <- Bolt.stream_pull(state.client, %{n: -1}, timeout(opts)),
           {:ok, response} <- Response.new(run, pull) do
        {:ok, query, response, state}
      else
        {:error, %Error{} = e} -> recover(e, opts, state)
        {:error, e} -> disconnect_result(e, state)
      end
    end

    # A server FAILURE is fully consumed. RESET before reusing an autocommit
    # connection; a failed explicit transaction is dropped instead of committed.
    defp recover(e, opts, %{status: :idle} = state) do
      case Client.request(state.client, :reset, [], timeout(opts)) do
        {:ok, _} -> {:error, e, state}
        {:error, _} -> disconnect_result(e, state)
      end
    end

    defp recover(e, _, state), do: disconnect_result(e, state)

    @impl true
    def handle_declare(_, _, _, %{cursor_open?: true} = state),
      do: {:error, %TransportError{reason: :cursor_already_open}, state}

    def handle_declare(query, params, opts, state) do
      case Bolt.stream_run(
             state.client,
             Bolt.statement_of(query),
             params,
             Keyword.get(opts, :run_extra, %{}),
             timeout(opts)
           ) do
        {:ok, run} -> {:ok, query, %{run: run}, %{state | first_chunk?: true, cursor_open?: true}}
        {:error, e} -> disconnect_result(e, state)
      end
    end

    @impl true
    def handle_fetch(_, %{run: run}, opts, state) do
      with {:ok, pull} <-
             Bolt.stream_pull(
               state.client,
               %{n: Keyword.get(opts, :chunk_size, 1000)},
               timeout(opts)
             ),
           :ok <- more_key(pull.success, state.first_chunk?),
           {:ok, response} <- Response.new(run, pull) do
        if Map.get(pull.success, "has_more", false),
          do: {:cont, response.results, %{state | first_chunk?: false}},
          else: {:halt, response.results, %{state | cursor_open?: false}}
      else
        {:error, e} -> disconnect_result(e, state)
      end
    end

    defp more_key(meta, first) do
      if (not first or Map.has_key?(meta, "has_more")) and
           Map.get(meta, "has_more", false) in [true, false],
         do: :ok,
         else: {:error, %TransportError{reason: :bolt_protocol_error}}
    end

    @impl true
    def handle_deallocate(_, _, opts, %{cursor_open?: true} = state) do
      case Client.request(state.client, :discard, [%{n: -1}], timeout(opts)) do
        {:ok, _} -> {:ok, :discarded, %{state | cursor_open?: false}}
        {:error, e} -> disconnect_result(e, state)
      end
    end

    def handle_deallocate(_, _, _, state), do: {:ok, :ok, state}

    defp disconnect_result(e, state),
      do: {:disconnect, Bolt.stream_error(e), Map.put(state, :cursor_open?, false)}

    defp timeout(opts), do: Keyword.get(opts, :timeout, :infinity)
  end
end
