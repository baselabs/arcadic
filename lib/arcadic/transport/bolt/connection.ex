# Guarded on Boltx so this compiles only when the optional boltx dep is present:
# the `defdelegate` targets `Boltx.Connection`, which must exist to resolve.
if Code.ensure_loaded?(Boltx) do
  defmodule Arcadic.Transport.Bolt.Connection do
    @moduledoc false
    use DBConnection

    alias Arcadic.Transport.Bolt
    alias Arcadic.TransportError
    alias Boltx.BoltProtocol.Message.{DiscardMessage, PullMessage, RunMessage}
    alias Boltx.Client

    import Boltx.BoltProtocol.ServerResponse, only: [statement_result: 1, pull_result: 2]

    # Inject the leak-safe connect; delegate every other DBConnection callback to
    # boltx unchanged. leak_safe_connect/1 returns a %Boltx.Error{} (already an
    # Exception) or a bare structural atom; DBConnection requires an Exception, so
    # the atom is normalized into %TransportError{} carrying ONLY that atom (Rule 3).
    @impl true
    def connect(opts) do
      case Bolt.leak_safe_connect(opts) do
        {:ok, state} -> {:ok, Map.put(state, :cursor_open?, false)}
        {:error, %Boltx.Error{} = e} -> {:error, redact(e)}
        {:error, reason} -> {:error, %TransportError{reason: reason}}
      end
    end

    # DBConnection logs a returned connect error via Exception.format_banner /
    # crash_reason. A %Boltx.Error{} carries the server FAILURE `message` (free text) in
    # its `bolt` map; that must not ride into the log (Rule 3). Strip the message while
    # preserving the exception type and the error code (spec L9 — :unauthorized retained)
    # and bolt.code (the Neo4j status class, Rule-3-permitted). Mirrors bolt_error/1, which
    # keeps only bolt.code on the streaming path.
    defp redact(%Boltx.Error{bolt: %{} = bolt} = e), do: %{e | bolt: Map.put(bolt, :message, nil)}
    defp redact(%Boltx.Error{} = e), do: e

    @impl true
    defdelegate disconnect(err, state), to: Boltx.Connection

    @impl true
    defdelegate checkout(state), to: Boltx.Connection

    # No DBConnection `checkin` callback exists — mirror boltx (delegate, un-@impl'd).
    defdelegate checkin(state), to: Boltx.Connection

    @impl true
    defdelegate ping(state), to: Boltx.Connection

    @impl true
    defdelegate handle_begin(opts, state), to: Boltx.Connection

    @impl true
    defdelegate handle_commit(opts, state), to: Boltx.Connection

    @impl true
    defdelegate handle_rollback(opts, state), to: Boltx.Connection

    @impl true
    def handle_execute(_query, _params, _opts, %{cursor_open?: true} = state) do
      # A cursor holds the connection's single active result; an execute RUN mid-cursor
      # desyncs the shared tx socket (db_connection.ex:920 — no re-checkout). Fail closed.
      {:error, %TransportError{reason: :cursor_open}, state}
    end

    def handle_execute(query, params, opts, state),
      do: Boltx.Connection.handle_execute(query, params, opts, state)

    @impl true
    defdelegate handle_prepare(query, opts, state), to: Boltx.Connection

    @impl true
    defdelegate handle_close(query, opts, state), to: Boltx.Connection

    @impl true
    def handle_declare(_query, _params, _opts, %{cursor_open?: true} = state) do
      {:error, %TransportError{reason: :cursor_already_open}, state}
    end

    def handle_declare(query, params, opts, state) do
      %{client: client} = state
      statement = Bolt.statement_of(query)

      payload =
        RunMessage.encode(
          client.bolt_version,
          statement,
          Bolt.format_params(params),
          run_extra(opts)
        )

      with :ok <- Client.send_packet(client, payload),
           {:ok, run} <-
             Client.recv_packets(client, &RunMessage.prepare_messages/2, timeout(opts)) do
        # `first_chunk?` is not a %Boltx.Connection{} field, so seed it with Map.put (the
        # `%{state | ...}` update syntax raises KeyError on an absent key); `cursor_open?`
        # already exists (seeded in connect/1) and updates via the struct-update below.
        state = state |> Map.put(:first_chunk?, true) |> Map.put(:cursor_open?, true)
        {:ok, query, %{run: run}, state}
      else
        # A send/recv failure is a WIRE fault (a recv timeout leaves the reply in flight): the
        # tx socket is now desynced. Return {:disconnect, …} — {:error, …} keeps the poisoned
        # connection checked in, and boltx's later COMMIT/ROLLBACK would read the stale reply.
        {:error, reason} -> {:disconnect, Bolt.stream_error(reason), state}
      end
    end

    @impl true
    def handle_fetch(_query, %{run: run}, opts, state) do
      %{client: client, first_chunk?: first} = state
      chunk = Keyword.get(opts, :chunk_size, 1000)
      payload = PullMessage.encode(client.bolt_version, %{n: chunk})

      with :ok <- Client.send_packet(client, payload),
           {:ok, pull} <-
             Client.recv_packets(client, &PullMessage.prepare_messages/2, timeout(opts)) do
        rows = Boltx.Response.new(statement_result(result_run: run, result_pull: pull)).results
        success = pull_result(pull, :success_data)
        # Parity with the non-tx stream sibling (bolt.ex assert_has_more_key!/2): a missing
        # `has_more` on the FIRST chunk is driver/server drift — fail LOUD (redacted
        # :bolt_protocol_error), never silently truncate the stream to its first chunk.
        Bolt.assert_has_more_key!(success, first)

        if Map.get(success, "has_more", false),
          do: {:cont, rows, %{state | first_chunk?: false}},
          else: {:halt, rows, %{state | cursor_open?: false}}
      else
        # WIRE fault mid-PULL (or a server FAILURE reply): the socket is off-by-one. DISCONNECT so
        # the poisoned connection is dropped, and clear `cursor_open?` so the deallocate that still
        # runs during cleanup does NOT fire a DISCARD against the desynced/failed socket (which
        # would read a stale reply, or hit boltx's IGNORED parse gap → CaseClauseError).
        {:error, reason} ->
          {:disconnect, Bolt.stream_error(reason), %{state | cursor_open?: false}}
      end
    end

    @impl true
    def handle_deallocate(_query, _cursor, opts, %{cursor_open?: true} = state) do
      # Caller halted the Stream early (or the tx body raised): DISCARD the remaining server-side
      # result so the tx's later COMMIT/ROLLBACK does not desync. If the DISCARD itself fails, the
      # socket is desynced — DISCONNECT (drop the pooled conn) rather than return it dirty as {:ok}.
      %{client: client} = state
      payload = DiscardMessage.encode(client.bolt_version, %{n: -1})

      with :ok <- Client.send_packet(client, payload),
           {:ok, _} <-
             Client.recv_packets(client, &DiscardMessage.prepare_messages/2, timeout(opts)) do
        {:ok, :discarded, %{state | cursor_open?: false}}
      else
        {:error, reason} ->
          {:disconnect, Bolt.stream_error(reason), %{state | cursor_open?: false}}
      end
    end

    def handle_deallocate(_query, _cursor, _opts, state), do: {:ok, :ok, state}

    @impl true
    defdelegate handle_status(opts, state), to: Boltx.Connection

    defp run_extra(opts), do: Keyword.get(opts, :run_extra, %{})
    defp timeout(opts), do: Keyword.get(opts, :timeout, :infinity)
  end
end
