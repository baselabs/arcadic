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
  delivers an `:overflow` marker. **Any marker obligates the consumer to
  reconcile the affected database** — the feed is a change *hint*, not a durable
  log.

  The subscriber may also receive an out-of-band error message
  `{:arcadic_change_error, reason}`: `:unauthorized` (a terminal `401`/`403` on the
  handshake — the process then stops, no reconnect spin) or `:subscribe_rejected`
  (the server rejected a subscribe/unsubscribe with an error frame; non-terminal —
  the socket stays open). Both reasons are bare atoms — the server's error text is
  never forwarded.

  ## Subscriber model

  One subscriber pid per process. The first `subscribe/3` binds the subscriber and
  monitors it; later subscribes on other databases route to that same pid (demux
  on `Event.database`). A subscribe with a different `:subscriber` is rejected
  `{:error, :subscriber_conflict}`. The subscriber's `:DOWN` stops the process.

  ## Backpressure

  A bounded internal buffer (`:max_buffer`, default 1000) drops the **oldest**
  events on overflow, emits an `:overflow` marker plus a
  `[:arcadic, :changes, :dropped]` telemetry count per drain cycle in which events
  were dropped (a short burst coalesces into a single marker; a sustained overflow
  emits one roughly per drain cycle), and keeps reading the socket. The buffer
  bounds **arcadic's** memory and guarantees a slow subscriber never wedges the
  *server* (the socket is drained continuously); it does not bound the subscriber's
  own mailbox — a persistently slow consumer must apply its own backpressure (or
  reconcile on the markers and discard).

  ## Absent optional dependency

  The WebSocket client rides the optional `mint_web_socket` dependency. This
  module always compiles; if the dependency is absent, `start_link/1` returns
  `{:error, :mint_web_socket_not_available}` at runtime. `start_link/1` also
  rejects a malformed `:conn` value-free — see `Arcadic.Error` for the
  `:invalid_auth` / `:invalid_url_scheme` / `:invalid_max_buffer` reasons.

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
  alias Arcadic.Opts
  alias Arcadic.Telemetry

  @change_types [:create, :update, :delete]

  @default_max_buffer 1000

  # Delivery debounce: coalesce a burst into one drain so overflow signals once.
  @drain_interval 15
  # ...but never hold a pending event longer than this (bounded latency under load).
  @drain_max_wait 150

  @backoff_base 50
  @backoff_cap 5_000

  # Bound the synchronous TCP connect so it cannot wedge a caller's `subscribe`/`unsubscribe`
  # `GenServer.call` against an unreachable host. Deliberately BELOW the 5s `GenServer.call`
  # default so the process frees up (times out the connect) before a queued call would.
  @connect_timeout 4_000
  # Bound the WHOLE establishment (connect → 101 upgrade); a peer that accepts TCP but never
  # completes the handshake would otherwise leave the process stuck in `:upgrading` forever.
  @establish_timeout 10_000

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
    :establish_timer,
    # Kept a list (never nil) so `Mint.WebSocket.new/4`'s success return survives dialyzer.
    upgrade_headers: [],
    subscriptions: %{},
    phase: :connecting,
    reconnect_attempts: 0,
    opened_once?: false,
    buffer: nil,
    buffer_size: 0,
    dropped: 0,
    establish_timeout: @establish_timeout
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
  @spec start_link(keyword()) ::
          GenServer.on_start()
          | {:error,
             :mint_web_socket_not_available
             | :invalid_conn
             | :invalid_auth
             | :invalid_url_scheme
             | :invalid_max_buffer
             | :invalid_establish_timeout}
  def start_link(opts) when is_list(opts) do
    with :ok <- ensure_mint_web_socket(),
         :ok <- validate_start_opts(opts) do
      {name, opts} = Keyword.pop(opts, :name)
      GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
    end
  end

  defp ensure_mint_web_socket do
    if Code.ensure_loaded?(Mint.WebSocket),
      do: :ok,
      else: {:error, :mint_web_socket_not_available}
  end

  # Validate the caller-supplied conn + max_buffer value-free BEFORE starting the process, so a
  # malformed input returns a typed `{:error, _}` instead of (a) crash-looping under `:transient`
  # restart or (b) leaking the value through a FunctionClauseError / `Access` blame (Rule 3).
  defp validate_start_opts(opts) do
    with :ok <- validate_conn(Keyword.get(opts, :conn)),
         :ok <- validate_max_buffer(Keyword.get(opts, :max_buffer, @default_max_buffer)) do
      validate_establish_timeout(Keyword.get(opts, :establish_timeout, @establish_timeout))
    end
  end

  defp validate_conn(%Arcadic.Conn{auth: auth, base_url: base_url}) do
    with :ok <- validate_auth(auth), do: validate_scheme(base_url)
  end

  defp validate_conn(_), do: {:error, :invalid_conn}

  # `conn.auth` reaches the `/ws` handshake headers; a shape other than `{u, p}` / `{:bearer, t}`
  # would FunctionClauseError in `auth_headers/1` and blame-echo the credentials (Rule 3). Reject
  # value-free here — the bare atom never carries the auth value.
  defp validate_auth({:bearer, token}) when is_binary(token), do: :ok
  defp validate_auth({user, pass}) when is_binary(user) and is_binary(pass), do: :ok
  defp validate_auth(_), do: {:error, :invalid_auth}

  # Only the four known ws/http schemes are accepted; an unrecognized scheme (e.g. a "htps" typo)
  # must NOT silently downgrade to plaintext `:ws` and send the Basic-auth header in the clear.
  defp validate_scheme(base_url) when is_binary(base_url) do
    case URI.parse(base_url).scheme do
      s when s in ["http", "https", "ws", "wss"] -> :ok
      _ -> {:error, :invalid_url_scheme}
    end
  end

  defp validate_scheme(_), do: {:error, :invalid_url_scheme}

  defp validate_max_buffer(n) when is_integer(n) and n >= 1, do: :ok
  defp validate_max_buffer(_), do: {:error, :invalid_max_buffer}

  # `:establish_timeout` is an advanced/tuning seam fed to `Process.send_after/3`; a non-positive-int
  # would crash `do_connect` and (under `restart: :transient`) restart-loop. Reject value-free.
  defp validate_establish_timeout(n) when is_integer(n) and n >= 1, do: :ok
  defp validate_establish_timeout(_), do: {:error, :invalid_establish_timeout}

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
  def subscribe(client, database, opts \\ [])

  def subscribe(client, database, opts) when is_binary(database) do
    Opts.validate_keys!(opts, [:type, :change_types, :subscriber])
    subscriber = validate_subscriber(Keyword.get(opts, :subscriber, self()))
    type = validate_type(Keyword.get(opts, :type))
    change_types = normalize_change_types(Keyword.get(opts, :change_types))
    GenServer.call(client, {:subscribe, database, type, change_types, subscriber})
  end

  # Total fallback: a non-binary `database` would FunctionClauseError BEFORE the guards above run and
  # blame-echo the `type`/`subscriber` opts (Rule 3). Reject value-free.
  def subscribe(_client, _database, _opts),
    do: raise(ArgumentError, "database must be a string")

  # Value-free (Rule 3): a non-pid subscriber or non-binary type would otherwise crash-echo the
  # caller value — the subscriber via `Process.monitor/1`, the type via `Jason.encode!` in the
  # subscribe frame. Guard both here, in the caller's process, before the `GenServer.call`.
  defp validate_subscriber(pid) when is_pid(pid), do: pid
  defp validate_subscriber(_), do: raise(ArgumentError, "subscriber must be a pid")

  defp validate_type(nil), do: nil
  defp validate_type(type) when is_binary(type), do: type
  defp validate_type(_), do: raise(ArgumentError, "type must be a string")

  @doc "Unsubscribe `client` from change events on `database`."
  @spec unsubscribe(GenServer.server(), String.t()) :: :ok
  def unsubscribe(client, database) when is_binary(database) do
    GenServer.call(client, {:unsubscribe, database})
  end

  def unsubscribe(_client, _database),
    do: raise(ArgumentError, "database must be a string")

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
    # Backstop: the public `start_link/1` already validated these, but re-check so a DIRECT
    # `GenServer.start_link(__MODULE__, opts)` (bypassing our wrapper) still fails closed instead of
    # crash-downgrading (a bad scheme → plaintext + Basic auth in the clear; a bad auth → creds echo).
    case validate_start_opts(opts) do
      :ok ->
        state = %__MODULE__{
          conn: Keyword.fetch!(opts, :conn),
          max_buffer: Keyword.get(opts, :max_buffer, @default_max_buffer),
          establish_timeout: Keyword.get(opts, :establish_timeout, @establish_timeout),
          buffer: :queue.new()
        }

        {:ok, state, {:continue, :connect}}

      {:error, reason} ->
        {:stop, reason}
    end
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

  # Establishment deadline fired while still connecting/upgrading → the handshake stalled; reconnect.
  # A stale timeout after we already opened (or are already reconnecting) is ignored.
  def handle_info(:establish_timeout, %{phase: phase} = state)
      when phase in [:connecting, :upgrading],
      do: {:noreply, reconnect(state)}

  def handle_info(:establish_timeout, state), do: {:noreply, state}

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
    state = cancel_establish_timer(state)
    {http_scheme, ws_scheme, host, port} = parse_endpoint(state.conn.base_url)

    case Mint.HTTP.connect(http_scheme, host, port,
           protocols: [:http1],
           timeout: @connect_timeout
         ) do
      {:ok, mconn} ->
        headers = auth_headers(state.conn.auth)

        case Mint.WebSocket.upgrade(ws_scheme, mconn, "/ws", headers) do
          {:ok, mconn, ref} ->
            # Arm the establishment deadline: if the 101 never arrives we reconnect rather than
            # sit in `:upgrading` forever (cancelled on `on_open`).
            timer = Process.send_after(self(), :establish_timeout, state.establish_timeout)

            %{
              state
              | mconn: mconn,
                ref: ref,
                phase: :upgrading,
                upgrade_status: nil,
                upgrade_headers: [],
                establish_timer: timer
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
        {:terminal_auth, st2} -> {:halt, terminal_unauthorized(st2)}
      end
    end)
  end

  defp step({:status, ref, status}, %{ref: ref} = st), do: {:ok, %{st | upgrade_status: status}}

  defp step({:headers, ref, headers}, %{ref: ref} = st),
    do: {:ok, %{st | upgrade_headers: headers}}

  defp step({:done, ref}, %{ref: ref} = st) do
    case st.upgrade_status do
      101 -> {:ok, on_open(st)}
      # 401 (bad credentials) and 403 (forbidden) are both terminal auth failures — never spin.
      status when status in [401, 403] -> {:terminal_auth, st}
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
    st = cancel_establish_timer(st)

    case ws_new(st.mconn, st.ref, st.upgrade_headers) do
      {:ok, mconn, ws} ->
        # NB: `reconnect_attempts` is reset to 0 by `resubscribe/1` on full success — NOT here —
        # so a failure between the 101 and the first re-subscribe frame still grows the backoff.
        st = %{st | mconn: mconn, ws: ws, phase: :open, upgrade_status: nil, upgrade_headers: []}

        st =
          if st.opened_once? do
            st |> flush_pending() |> deliver_reconnected_markers()
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
    result =
      Enum.reduce_while(Map.to_list(st.subscriptions), st, fn {db, sub}, acc ->
        case send_frame(acc, subscribe_frame(db, sub)) do
          {:ok, acc2} -> {:cont, acc2}
          {:error, acc2} -> {:halt, reconnect(acc2)}
        end
      end)

    # Reset the backoff only once the socket is open AND every live subscription was re-sent (a
    # send failure above halts to `reconnect/1`, leaving `phase: :reconnecting` and the backoff grown).
    if result.phase == :open, do: %{result | reconnect_attempts: 0}, else: result
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
      {:ok, %{"result" => "error"}} -> {:ok, deliver_subscribe_error(st)}
      # Acks (`{"result":"ok"}`) and any other JSON are informational.
      _ -> {:ok, st}
    end
  end

  defp handle_frame({:close, _code, _reason}, st), do: {:reconnect, st}
  # A failed pong write means the socket is dead — reconnect rather than sit marked `:open`.
  defp handle_frame({:ping, data}, st), do: send_pong(st, data)
  defp handle_frame(_frame, st), do: {:ok, st}

  # A server `{"result":"error", ...}` frame rejects a subscribe/unsubscribe (the caller already got
  # an optimistic `:ok`). Surface it value-free — NEVER forward the server's `error`/`detail` strings
  # (they may echo caller/server data, Rule 3). Non-terminal: the socket stays open.
  defp deliver_subscribe_error(%{subscriber: sub} = st) when is_pid(sub) do
    send(sub, {:arcadic_change_error, :subscribe_rejected})
    st
  end

  defp deliver_subscribe_error(st), do: st

  # --- reconnect / terminal -----------------------------------------------------

  defp reconnect(state) do
    state = cancel_establish_timer(state)
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

  # Cancel any armed establishment deadline (idempotent).
  defp cancel_establish_timer(%{establish_timer: nil} = st), do: st

  defp cancel_establish_timer(%{establish_timer: timer} = st) do
    Process.cancel_timer(timer)
    %{st | establish_timer: nil}
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
          record = record_map(payload["record"])

          enqueue(st, %Event{
            database: db,
            type: payload["type"] || record["@type"] || sub.type,
            change_type: change_type,
            rid: record["@rid"],
            record: record
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

  # A well-formed ArcadeDB change frame carries a map `record`; a non-map (hostile/garbled frame)
  # must not reach `get_in`/`Access` (which would raise and blame-echo the value — Rule 3). Coerce a
  # non-map to `nil` value-free: the change signal is preserved, the malformed payload is dropped.
  defp record_map(record) when is_map(record), do: record
  defp record_map(_), do: nil

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

  # On reconnect, deliver any buffered pre-gap events (and their overflow marker) BEFORE the
  # `:reconnected` marker, so the marker cleanly separates pre-gap from post-gap delivery instead of
  # racing the debounced drain timer (which otherwise fires the buffer AFTER the marker).
  defp flush_pending(st) do
    if st.drain_timer, do: Process.cancel_timer(st.drain_timer)

    %{st | drain_timer: nil, pending_since: nil}
    |> deliver_overflow_marker()
    |> flush_buffer()
  end

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
      {:ok, %{st | ws: ws, mconn: mconn}}
    else
      _ -> {:reconnect, st}
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
