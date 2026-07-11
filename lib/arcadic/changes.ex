defmodule Arcadic.Changes.Event do
  @moduledoc """
  A single change-feed delivery from `Arcadic.Changes`.

  The subscriber receives `{:arcadic_change, %Arcadic.Changes.Event{}}` messages.
  `change_type` is `:create`, `:update`, or `:delete` for real record changes,
  plus two in-band control markers the consumer MUST act on:

    * `:reconnected` — the socket dropped and was re-established. ArcadeDB `/ws`
      has no replay, so any events in the gap are lost; reconcile `database`.
    * `:overflow` — the internal buffer overflowed and dropped the oldest events
      (a slow subscriber); reconcile. `database` is `nil` (the drop spans the
      subscription).

  `rid` is `record["@rid"]`, lifted for convenience.
  """

  @type change_type :: :create | :update | :delete | :reconnected | :overflow

  @type t :: %__MODULE__{
          database: String.t() | nil,
          type: String.t() | nil,
          change_type: change_type(),
          rid: String.t() | nil,
          record: map() | nil
        }

  defstruct [:database, :type, :change_type, :rid, :record]
end

defmodule Arcadic.Changes do
  @moduledoc """
  Live change-events client for ArcadeDB's `/ws` WebSocket feed — arcadic's
  one caller-supervised process.

  Start it under your own supervision tree, then `subscribe/3` a database. The
  process presents `conn.auth` on the handshake, keeps the socket drained
  continuously, and pushes each change to a single subscriber pid as
  `{:arcadic_change, %Arcadic.Changes.Event{}}` (see that struct for the marker
  contract).

  ## Reliability — best-effort at-most-once

  ArcadeDB `/ws` has **no replay or checkpoint**. On any reconnect the process
  delivers a `:reconnected` marker (before re-subscribing); on buffer overflow it
  delivers one `:overflow` marker. **Any marker obligates the consumer to
  reconcile the affected database** — the feed is a change *hint*, not a durable
  log.

  ## Subscriber model

  One subscriber pid per process. The first `subscribe/3` binds the subscriber and
  monitors it; later subscribes on other databases route to that same pid (demux
  on `Event.database`). A subscribe with a different `:subscriber` is rejected
  `{:error, :subscriber_conflict}`. The subscriber's `:DOWN` stops the process.

  ## Backpressure

  A bounded internal buffer (`:max_buffer`, default 1000) drops the **oldest**
  events on overflow, emits one `:overflow` marker plus a
  `[:arcadic, :changes, :dropped]` telemetry count, and keeps reading the socket
  (a slow subscriber never wedges the server).

  ## Absent optional dependency

  The WebSocket client rides the optional `mint_web_socket` dependency. This
  module always compiles; if the dependency is absent, `start_link/1` returns
  `{:error, :mint_web_socket_not_available}` at runtime.

  ## Telemetry

  `[:arcadic, :changes, :start | :stop | :disconnect | :dropped]`, all with
  value-free metadata `%{operation: :changes}` (no database, record, or values).
  """

  # `:transient` (not the `use GenServer` default `:permanent`): both terminal paths
  # stop with `{:stop, :normal, _}` — a 401 (re)handshake and the subscriber's `:DOWN`.
  # A `:permanent` child is restarted by a caller's supervisor after ANY exit, including
  # `:normal`, which would re-init → re-handshake → 401 → stop → restart: a supervision-
  # level spin that defeats the in-process "terminal, no spin" guarantee. `:transient`
  # restarts on ABNORMAL exit (crash recovery preserved) but NOT on a `:normal` stop.
  use GenServer, restart: :transient

  # `mint_web_socket` is OPTIONAL. This module is ALWAYS compiled and references
  # `Mint.WebSocket` only through runtime remote calls (its `decode/2` yields
  # tuples, never structs) so a consumer without the dep still compiles. Suppress
  # the absent-module xref warning here (not in mix.exs) so the compile-without-dep
  # gate stays clean; a struct match would be a hard error this cannot mask, and
  # there are none. `Mint.HTTP` rides `mint` (transitive via req/finch), always present.
  @compile {:no_warn_undefined, Mint.WebSocket}

  alias Arcadic.Changes.Event
  alias Arcadic.Telemetry

  @change_types [:create, :update, :delete]

  @default_max_buffer 1000

  # Delivery debounce: coalesce a burst into one drain so overflow signals once.
  @drain_interval 15
  # ...but never hold a pending event longer than this (bounded latency under load).
  @drain_max_wait 150

  @backoff_base 50
  @backoff_cap 5_000

  defstruct [
    :conn,
    :max_buffer,
    :subscriber,
    :subscriber_ref,
    :mconn,
    :ref,
    :ws,
    :upgrade_status,
    :drain_timer,
    :pending_since,
    # Kept a list (never nil) so `Mint.WebSocket.new/4`'s success return survives dialyzer.
    upgrade_headers: [],
    subscriptions: %{},
    phase: :connecting,
    reconnect_attempts: 0,
    opened_once?: false,
    buffer: nil,
    buffer_size: 0,
    dropped: 0
  ]

  # --- public API ---------------------------------------------------------------

  @doc """
  Start the change-events process.

  ## Options
    * `:conn` — an `Arcadic.Conn` (required). Supplies the `/ws` endpoint
      (`base_url`) and handshake credential (`auth`).
    * `:name` — optional `GenServer` name.
    * `:max_buffer` — bounded delivery buffer (default `#{@default_max_buffer}`).

  Returns `{:error, :mint_web_socket_not_available}` when the optional
  `mint_web_socket` dependency is absent.
  """
  @spec start_link(keyword()) :: GenServer.on_start() | {:error, :mint_web_socket_not_available}
  def start_link(opts) when is_list(opts) do
    if Code.ensure_loaded?(Mint.WebSocket) do
      {name, opts} = Keyword.pop(opts, :name)
      GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
    else
      {:error, :mint_web_socket_not_available}
    end
  end

  @doc """
  Subscribe `client` to change events on `database`.

  ## Options
    * `:type` — restrict to a document/vertex/edge type (default: all types).
    * `:change_types` — a subset of `#{inspect(@change_types)}` (default: all).
    * `:subscriber` — the pid to deliver events to. **Defaults to `self()`
      evaluated here in the caller's process** (never the process running the
      GenServer), so a supervised `Changes` still routes to the subscribing caller.

  The first subscribe binds the subscriber; a later subscribe with a different
  subscriber returns `{:error, :subscriber_conflict}`.
  """
  @spec subscribe(GenServer.server(), String.t(), keyword()) ::
          :ok | {:error, :subscriber_conflict}
  def subscribe(client, database, opts \\ []) when is_binary(database) do
    subscriber = Keyword.get(opts, :subscriber, self())
    type = Keyword.get(opts, :type)
    change_types = normalize_change_types(Keyword.get(opts, :change_types))
    GenServer.call(client, {:subscribe, database, type, change_types, subscriber})
  end

  @doc "Unsubscribe `client` from change events on `database`."
  @spec unsubscribe(GenServer.server(), String.t()) :: :ok
  def unsubscribe(client, database) when is_binary(database) do
    GenServer.call(client, {:unsubscribe, database})
  end

  defp normalize_change_types(nil), do: :all

  defp normalize_change_types(list) when is_list(list) do
    if Enum.all?(list, &(&1 in @change_types)) do
      list
    else
      raise ArgumentError, "change_types must be a subset of #{inspect(@change_types)}"
    end
  end

  defp normalize_change_types(_other),
    do: raise(ArgumentError, "change_types must be a list, subset of #{inspect(@change_types)}")

  # --- GenServer lifecycle ------------------------------------------------------

  @impl true
  def init(opts) do
    state = %__MODULE__{
      conn: Keyword.fetch!(opts, :conn),
      max_buffer: Keyword.get(opts, :max_buffer, @default_max_buffer),
      buffer: :queue.new()
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: {:noreply, do_connect(state)}

  @impl true
  def terminate(_reason, state) do
    Telemetry.event([:arcadic, :changes, :stop], %{system_time: System.system_time()}, %{
      operation: :changes
    })

    close_conn(state)
    :ok
  end

  # --- subscribe / unsubscribe --------------------------------------------------

  @impl true
  def handle_call({:subscribe, db, type, change_types, subscriber}, _from, state) do
    cond do
      state.subscriber == nil ->
        ref = Process.monitor(subscriber)
        state = %{state | subscriber: subscriber, subscriber_ref: ref}
        {:reply, :ok, add_subscription(state, db, type, change_types)}

      state.subscriber == subscriber ->
        {:reply, :ok, add_subscription(state, db, type, change_types)}

      # Value-free: never echo the conflicting pid (Rule 3).
      true ->
        {:reply, {:error, :subscriber_conflict}, state}
    end
  end

  def handle_call({:unsubscribe, db}, _from, state) do
    state = %{state | subscriptions: Map.delete(state.subscriptions, db)}
    state = if state.phase == :open, do: push_unsubscribe(state, db), else: state
    {:reply, :ok, state}
  end

  defp add_subscription(state, db, type, change_types) do
    subscriptions = Map.put(state.subscriptions, db, %{type: type, change_types: change_types})
    state = %{state | subscriptions: subscriptions}
    if state.phase == :open, do: push_subscribe(state, db), else: state
  end

  # --- control messages ---------------------------------------------------------

  @impl true
  def handle_info(:drain, state) do
    state = %{state | drain_timer: nil}
    state = deliver_overflow_marker(state)
    state = flush_buffer(state)
    {:noreply, %{state | pending_since: nil}}
  end

  def handle_info(:reconnect, %{phase: :reconnecting} = state),
    do: {:noreply, do_connect(state)}

  def handle_info(:reconnect, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{subscriber_ref: ref} = state),
    do: {:stop, :normal, state}

  # No live connection (between reconnect attempts): ignore stray socket traffic.
  def handle_info(_message, %{mconn: nil} = state), do: {:noreply, state}

  # Socket traffic for the live Mint connection.
  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.mconn, message) do
      {:ok, mconn, responses} ->
        process_responses(responses, %{state | mconn: mconn})

      {:error, mconn, _reason, _responses} ->
        {:noreply, reconnect(%{state | mconn: mconn})}

      :unknown ->
        {:noreply, state}
    end
  end

  # --- connection state machine -------------------------------------------------

  defp do_connect(state) do
    {http_scheme, ws_scheme, host, port} = parse_endpoint(state.conn.base_url)

    case Mint.HTTP.connect(http_scheme, host, port, protocols: [:http1]) do
      {:ok, mconn} ->
        headers = auth_headers(state.conn.auth)

        case Mint.WebSocket.upgrade(ws_scheme, mconn, "/ws", headers) do
          {:ok, mconn, ref} ->
            %{
              state
              | mconn: mconn,
                ref: ref,
                phase: :upgrading,
                upgrade_status: nil,
                upgrade_headers: []
            }

          {:error, mconn, _reason} ->
            reconnect(%{state | mconn: mconn})
        end

      {:error, _reason} ->
        reconnect(%{state | mconn: nil})
    end
  end

  defp process_responses(responses, state) do
    Enum.reduce_while(responses, {:noreply, state}, fn resp, {_tag, st} ->
      case step(resp, st) do
        {:ok, st2} -> {:cont, {:noreply, st2}}
        {:reconnect, st2} -> {:halt, {:noreply, reconnect(st2)}}
        {:terminal_401, st2} -> {:halt, terminal_unauthorized(st2)}
      end
    end)
  end

  defp step({:status, ref, status}, %{ref: ref} = st), do: {:ok, %{st | upgrade_status: status}}

  defp step({:headers, ref, headers}, %{ref: ref} = st),
    do: {:ok, %{st | upgrade_headers: headers}}

  defp step({:done, ref}, %{ref: ref} = st) do
    case st.upgrade_status do
      101 -> {:ok, on_open(st)}
      401 -> {:terminal_401, st}
      _ -> {:reconnect, st}
    end
  end

  # Data on an established socket = WebSocket frames.
  defp step({:data, ref, data}, %{ref: ref, ws: ws} = st) when ws != nil,
    do: decode_and_handle(data, st)

  # Data before the upgrade completes (e.g. a non-101 error body): ignore it.
  defp step({:data, ref, _data}, %{ref: ref} = st), do: {:ok, st}

  defp step({:error, ref, _reason}, %{ref: ref} = st), do: {:reconnect, st}

  defp step(_other, st), do: {:ok, st}

  defp on_open(st) do
    case ws_new(st.mconn, st.ref, st.upgrade_headers) do
      {:ok, mconn, ws} ->
        st = %{
          st
          | mconn: mconn,
            ws: ws,
            phase: :open,
            reconnect_attempts: 0,
            upgrade_status: nil,
            upgrade_headers: []
        }

        st =
          if st.opened_once? do
            deliver_reconnected_markers(st)
          else
            emit(:start)
            %{st | opened_once?: true}
          end

        resubscribe(st)

      {:error, mconn, _reason} ->
        reconnect(%{st | mconn: mconn})
    end
  end

  # `Mint.WebSocket.new/4`'s inferred success typing collapses to `{:error, ...}`:
  # dialyzer cannot see that `upgrade/4` stashed the sec-websocket-key in the conn's
  # private store (that flows across GenServer callbacks), so it deems the accept-nonce
  # check unsatisfiable. A known dependency false positive. `apply/3` erases that one
  # over-narrow return so the runtime-reachable `{:ok, ...}` branch stays live for
  # dialyzer — keeping FULL dialyzer coverage elsewhere, with no ignore file and no
  # `@dialyzer` suppression. The static-arity apply is the whole point here, so the
  # matching credo style check is disabled for this single justified line.
  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  defp ws_new(mconn, ref, headers), do: apply(Mint.WebSocket, :new, [mconn, ref, 101, headers])

  defp resubscribe(st) do
    Enum.reduce_while(Map.to_list(st.subscriptions), st, fn {db, sub}, acc ->
      case send_frame(acc, subscribe_frame(db, sub)) do
        {:ok, acc2} -> {:cont, acc2}
        {:error, acc2} -> {:halt, reconnect(acc2)}
      end
    end)
  end

  defp decode_and_handle(data, st) do
    case Mint.WebSocket.decode(st.ws, data) do
      {:ok, ws, frames} -> Enum.reduce_while(frames, {:ok, %{st | ws: ws}}, &reduce_frame/2)
      {:error, ws, _reason} -> {:reconnect, %{st | ws: ws}}
    end
  end

  defp reduce_frame(frame, {_tag, st}) do
    case handle_frame(frame, st) do
      {:ok, st2} -> {:cont, {:ok, st2}}
      {:reconnect, st2} -> {:halt, {:reconnect, st2}}
    end
  end

  defp handle_frame({:text, text}, st) do
    case Jason.decode(text) do
      {:ok, %{"changeType" => _} = payload} -> {:ok, ingest_change(st, payload)}
      # Acks (`{"result":"ok"}`) and any non-change JSON are informational.
      _ -> {:ok, st}
    end
  end

  defp handle_frame({:close, _code, _reason}, st), do: {:reconnect, st}
  defp handle_frame({:ping, data}, st), do: {:ok, send_pong(st, data)}
  defp handle_frame(_frame, st), do: {:ok, st}

  # --- reconnect / terminal -----------------------------------------------------

  defp reconnect(state) do
    close_conn(state)
    attempts = state.reconnect_attempts
    Process.send_after(self(), :reconnect, backoff_ms(attempts))

    %{
      state
      | phase: :reconnecting,
        mconn: nil,
        ws: nil,
        ref: nil,
        reconnect_attempts: attempts + 1,
        upgrade_status: nil,
        upgrade_headers: []
    }
  end

  defp terminal_unauthorized(state) do
    if is_pid(state.subscriber),
      do: send(state.subscriber, {:arcadic_change_error, :unauthorized})

    emit(:disconnect)
    close_conn(state)
    {:stop, :normal, %{state | phase: :terminal, mconn: nil, ws: nil, ref: nil}}
  end

  defp backoff_ms(attempt) do
    ceiling = min(@backoff_cap, @backoff_base * Integer.pow(2, min(attempt, 20)))
    # Full jitter in 1..ceiling — spreads reconnect storms, never a 0-delay tight loop.
    :rand.uniform(ceiling)
  end

  # --- change filtering + delivery ----------------------------------------------

  defp ingest_change(st, payload) do
    case match_subscription(st, payload) do
      {db, sub} ->
        change_type = parse_change_type(payload["changeType"])

        if allowed?(sub.change_types, change_type) do
          enqueue(st, %Event{
            database: db,
            type: payload["type"] || sub.type,
            change_type: change_type,
            rid: get_in(payload, ["record", "@rid"]),
            record: payload["record"]
          })
        else
          st
        end

      :none ->
        st
    end
  end

  # Real ArcadeDB frames carry the database; the fake harness omits it, so a lone
  # subscription is the unambiguous target. No matching subscription → drop.
  defp match_subscription(%{subscriptions: subs}, _payload) when map_size(subs) == 0, do: :none

  defp match_subscription(%{subscriptions: subs}, %{"database" => db}) when is_binary(db) do
    case subs do
      %{^db => sub} -> {db, sub}
      _ -> :none
    end
  end

  defp match_subscription(%{subscriptions: subs}, _payload) when map_size(subs) == 1 do
    [{db, sub}] = Map.to_list(subs)
    {db, sub}
  end

  defp match_subscription(_st, _payload), do: :none

  defp parse_change_type("create"), do: :create
  defp parse_change_type("update"), do: :update
  defp parse_change_type("delete"), do: :delete
  defp parse_change_type(_other), do: :unknown

  defp allowed?(:all, change_type), do: change_type in @change_types
  defp allowed?(list, change_type) when is_list(list), do: change_type in list

  # --- bounded buffer (drop-oldest) + debounced drain ---------------------------

  defp enqueue(st, %Event{} = event) do
    queue = :queue.in(event, st.buffer)
    {queue, size, dropped} = drop_to_bound(queue, st.buffer_size + 1, st.max_buffer, 0)

    st
    |> Map.merge(%{buffer: queue, buffer_size: size, dropped: st.dropped + dropped})
    |> schedule_drain()
  end

  defp drop_to_bound(queue, size, max, dropped) when size > max do
    {{:value, _oldest}, rest} = :queue.out(queue)
    drop_to_bound(rest, size - 1, max, dropped + 1)
  end

  defp drop_to_bound(queue, size, _max, dropped), do: {queue, size, dropped}

  defp schedule_drain(st) do
    now = System.monotonic_time(:millisecond)
    pending_since = st.pending_since || now
    wait = min(@drain_interval, max(0, pending_since + @drain_max_wait - now))
    if st.drain_timer, do: Process.cancel_timer(st.drain_timer)
    %{st | drain_timer: Process.send_after(self(), :drain, wait), pending_since: pending_since}
  end

  defp deliver_overflow_marker(%{dropped: dropped, subscriber: sub} = st)
       when dropped > 0 and is_pid(sub) do
    Telemetry.event([:arcadic, :changes, :dropped], %{count: dropped}, %{operation: :changes})
    send(sub, {:arcadic_change, %Event{change_type: :overflow, database: nil}})
    %{st | dropped: 0}
  end

  defp deliver_overflow_marker(st), do: st

  defp flush_buffer(%{subscriber: sub} = st) when is_pid(sub) do
    Enum.each(:queue.to_list(st.buffer), &send(sub, {:arcadic_change, &1}))
    %{st | buffer: :queue.new(), buffer_size: 0}
  end

  defp flush_buffer(st), do: st

  defp deliver_reconnected_markers(%{subscriber: sub} = st) when is_pid(sub) do
    Enum.each(Map.keys(st.subscriptions), fn db ->
      send(sub, {:arcadic_change, %Event{change_type: :reconnected, database: db}})
    end)

    st
  end

  defp deliver_reconnected_markers(st), do: st

  # --- frame sending ------------------------------------------------------------

  defp push_subscribe(st, db),
    do: send_or_reconnect(st, subscribe_frame(db, st.subscriptions[db]))

  defp push_unsubscribe(st, db),
    do: send_or_reconnect(st, %{"action" => "unsubscribe", "database" => db})

  defp send_or_reconnect(st, frame) do
    case send_frame(st, frame) do
      {:ok, st2} -> st2
      {:error, st2} -> reconnect(st2)
    end
  end

  defp subscribe_frame(db, sub) do
    %{"action" => "subscribe", "database" => db}
    |> maybe_put("type", sub.type)
    |> put_change_types(sub.change_types)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp put_change_types(map, :all), do: map

  defp put_change_types(map, list) when is_list(list),
    do: Map.put(map, "changeTypes", Enum.map(list, &Atom.to_string/1))

  # On any send failure the caller reconnects (which closes + resets the socket),
  # so the precise post-error socket handle is moot — return the state unchanged
  # rather than pattern-matching the opaque Mint error term.
  defp send_frame(st, frame) do
    with {:ok, ws, data} <- Mint.WebSocket.encode(st.ws, {:text, Jason.encode!(frame)}),
         {:ok, mconn} <- Mint.WebSocket.stream_request_body(st.mconn, st.ref, data) do
      {:ok, %{st | ws: ws, mconn: mconn}}
    else
      _error -> {:error, st}
    end
  end

  defp send_pong(st, data) do
    with {:ok, ws, frame} <- Mint.WebSocket.encode(st.ws, {:pong, data}),
         {:ok, mconn} <- Mint.WebSocket.stream_request_body(st.mconn, st.ref, frame) do
      %{st | ws: ws, mconn: mconn}
    else
      _ -> st
    end
  end

  # --- helpers ------------------------------------------------------------------

  defp parse_endpoint(base_url) do
    uri = URI.parse(base_url)

    {http_scheme, ws_scheme} =
      case uri.scheme do
        s when s in ["https", "wss"] -> {:https, :wss}
        _ -> {:http, :ws}
      end

    default_port = if http_scheme == :https, do: 443, else: 80
    {http_scheme, ws_scheme, uri.host, uri.port || default_port}
  end

  defp auth_headers({:bearer, token}), do: [{"authorization", "Bearer " <> token}]

  defp auth_headers({user, pass}),
    do: [{"authorization", "Basic " <> Base.encode64(user <> ":" <> pass)}]

  defp close_conn(%{mconn: nil}), do: :ok
  defp close_conn(%{mconn: mconn}), do: Mint.HTTP.close(mconn)

  defp emit(event) do
    Telemetry.event([:arcadic, :changes, event], %{system_time: System.system_time()}, %{
      operation: :changes
    })
  end
end
