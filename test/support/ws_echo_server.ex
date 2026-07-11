defmodule WsEchoServer do
  @moduledoc """
  A test-only, real listening WebSocket server for driving `Arcadic.Changes`
  (and any other `Mint.WebSocket` client) deterministically.

  `mint_web_socket` opens a genuine TCP/HTTP connection, so `Req.Test` cannot
  serve it. This is the `WebSock`-based sibling of the raw-`:gen_tcp`
  `Arcadic.Test.BoltFakeServer`: a `Bandit`-served `/ws` endpoint plus a
  controller API so a test drives the wire without timing races.

  ## Lifecycle

      {:ok, port} = WsEchoServer.start(self())

  `start/1` boots a `Bandit` listener on an ephemeral port (`port: 0`) as an
  ExUnit-supervised child, so the server and its port are torn down when the
  test finishes (no cross-test leaks). The `controller` pid receives a
  `{:ws_echo, action, decoded_frame}` message for every inbound text frame.

  ## Control API (all keyed by the returned `port`)

    * `push/3` — deliver a `{"changeType" => ct, "record" => record}` text
      frame to the live client.
    * `drop/1` — stop the live connection (server-initiated close).
    * `reject_next_handshake/1` — make the *next* `GET /ws` upgrade answer `401`
      (one-shot; the handshake after it succeeds again).

  ## Wiring

  Each server is identified by a `ref` baked into its `Plug` options at boot
  (the port is not known until after `Bandit` binds). A single named `Agent`
  maps `ref => %{port, controller, reject_next?, handler}`. The handler
  self-registers its pid on `init/1`; the control API resolves `port -> ref ->
  entry` and messages the handler directly.
  """

  @registry __MODULE__.Registry

  # Bandit runs Handler.init/1 (which self-registers the handler pid)
  # concurrently with the client observing the 101 upgrade, so push/3 and drop/1
  # may be called before the handler exists. Poll for it, bounded, then fail
  # closed with a clear error rather than send(nil, ...).
  @handler_wait_ms 1_000
  @handler_poll_ms 10

  @typedoc "Opaque per-server identifier baked into the plug options."
  @type ref :: reference()

  @doc """
  Boot an ephemeral `/ws` server whose inbound frames are recorded to
  `controller`. Returns `{:ok, port}`.

  Must be called from an ExUnit test process: the `Bandit` listener is started
  via `ExUnit.Callbacks.start_supervised!/1` so it is cleaned up at test exit.
  """
  @spec start(pid()) :: {:ok, :inet.port_number()}
  def start(controller) when is_pid(controller) do
    ensure_registry()
    ref = make_ref()

    pid =
      ExUnit.Callbacks.start_supervised!(
        {Bandit, plug: {__MODULE__.Plug, %{ref: ref}}, scheme: :http, port: 0, startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)

    Agent.update(@registry, fn state ->
      Map.put(state, ref, %{
        ref: ref,
        port: port,
        controller: controller,
        reject_next?: false,
        hang_next?: false,
        handler: nil
      })
    end)

    # Drop this server's entry at test exit. ExUnit tears down supervised
    # children (the Bandit server) in a phase BEFORE running on_exit callbacks,
    # so Bandit is already down when this delete runs; the exact ordering is
    # irrelevant here — either way the ref-keyed entry is removed before the
    # next (async: false) test can be handed the same reused ephemeral port, so
    # find_by_port/2 never sees a stale entry.
    ExUnit.Callbacks.on_exit(fn -> Agent.update(@registry, &Map.delete(&1, ref)) end)

    {:ok, port}
  end

  @doc "Push a change frame to the live client on `port` (record is any JSON term, so a test can send a malformed non-map record)."
  @spec push(:inet.port_number(), String.t(), term()) :: :ok
  def push(port, change_type, record) do
    send(await_handler!(port), {:push, change_type, record})
    :ok
  end

  @doc "Stop the live connection on `port` (server-initiated close)."
  @spec drop(:inet.port_number()) :: :ok
  def drop(port) do
    send(await_handler!(port), :drop)
    :ok
  end

  @doc "Push a raw server error frame (a `result: error` JSON object) to the live client on `port`."
  @spec push_error(:inet.port_number(), String.t(), String.t()) :: :ok
  def push_error(port, error, detail) do
    send(await_handler!(port), {:push_error, error, detail})
    :ok
  end

  @doc "Arm a one-shot rejection (`status`, default `401`) on the next `/ws` upgrade for `port`."
  @spec reject_next_handshake(:inet.port_number(), 100..599) :: :ok
  def reject_next_handshake(port, status \\ 401) do
    %{ref: ref} = lookup_by_port!(port)

    Agent.update(@registry, fn state ->
      Map.update!(state, ref, &%{&1 | reject_next?: status})
    end)

    :ok
  end

  @doc "Arm a one-shot STALLED upgrade on the next `/ws` handshake: TCP is accepted but no 101 is ever sent."
  @spec hang_next_handshake(:inet.port_number()) :: :ok
  def hang_next_handshake(port) do
    %{ref: ref} = lookup_by_port!(port)

    Agent.update(@registry, fn state ->
      Map.update!(state, ref, &%{&1 | hang_next?: true})
    end)

    :ok
  end

  # --- registry internals (public so the Plug/Handler submodules can reach) ---

  @doc false
  @spec fetch_by_ref!(ref()) :: map()
  def fetch_by_ref!(ref), do: Agent.get(@registry, &Map.fetch!(&1, ref))

  @doc false
  @spec clear_reject(ref()) :: :ok
  def clear_reject(ref) do
    Agent.update(@registry, fn state ->
      Map.update!(state, ref, &%{&1 | reject_next?: false})
    end)
  end

  @doc false
  @spec clear_hang(ref()) :: :ok
  def clear_hang(ref) do
    Agent.update(@registry, fn state ->
      Map.update!(state, ref, &%{&1 | hang_next?: false})
    end)
  end

  @doc false
  @spec register_handler(ref(), pid()) :: :ok
  def register_handler(ref, handler) do
    Agent.update(@registry, fn state ->
      Map.update!(state, ref, &%{&1 | handler: handler})
    end)
  end

  defp lookup_by_port!(port) do
    Agent.get(@registry, &find_by_port(&1, port)) ||
      raise ArgumentError, "no WsEchoServer registered on port #{inspect(port)}"
  end

  defp find_by_port(state, port) do
    Enum.find_value(state, fn {_ref, entry} -> if entry.port == port, do: entry end)
  end

  defp await_handler!(port) do
    await_handler!(port, System.monotonic_time(:millisecond) + @handler_wait_ms)
  end

  defp await_handler!(port, deadline) do
    case lookup_by_port!(port) do
      %{handler: handler} when is_pid(handler) ->
        handler

      %{handler: nil} ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise ArgumentError,
                "WsEchoServer on port #{inspect(port)}: no handler registered " <>
                  "(client not connected?)"
        end

        Process.sleep(@handler_poll_ms)
        await_handler!(port, deadline)
    end
  end

  defp ensure_registry do
    case Agent.start(fn -> %{} end, name: @registry) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defmodule Plug do
    @moduledoc false
    @behaviour Elixir.Plug

    import Elixir.Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%{method: "GET", request_path: "/ws"} = conn, %{ref: ref}) do
      entry = WsEchoServer.fetch_by_ref!(ref)

      cond do
        is_integer(entry.reject_next?) ->
          :ok = WsEchoServer.clear_reject(ref)
          send_resp(conn, entry.reject_next?, "")

        entry.hang_next? ->
          # Accept the TCP/HTTP request but withhold the 101 long enough for the client's
          # establishment deadline to fire (tests use a ~150ms deadline). Kept short so it does not
          # block server teardown; the client has already reconnected on a fresh connection by then.
          :ok = WsEchoServer.clear_hang(ref)
          Process.sleep(600)
          send_resp(conn, 504, "")

        true ->
          WebSockAdapter.upgrade(
            conn,
            WsEchoServer.Handler,
            %{ref: ref, controller: entry.controller},
            timeout: 60_000
          )
      end
    end

    def call(conn, _opts), do: send_resp(conn, 404, "not found")
  end

  defmodule Handler do
    @moduledoc false
    @behaviour WebSock

    @impl true
    def init(%{ref: ref} = state) do
      :ok = WsEchoServer.register_handler(ref, self())
      {:ok, state}
    end

    @impl true
    def handle_in({text, [opcode: :text]}, state) do
      decoded = Jason.decode!(text)
      send(state.controller, {:ws_echo, decoded["action"], decoded})
      ack = Jason.encode!(%{"result" => "ok", "action" => decoded["action"]})
      {:push, {:text, ack}, state}
    end

    def handle_in(_frame, state), do: {:ok, state}

    @impl true
    def handle_info({:push, change_type, record}, state) do
      frame = Jason.encode!(%{"changeType" => change_type, "record" => record})
      {:push, {:text, frame}, state}
    end

    def handle_info({:push_error, error, detail}, state) do
      frame = Jason.encode!(%{"result" => "error", "error" => error, "detail" => detail})
      {:push, {:text, frame}, state}
    end

    def handle_info(:drop, state), do: {:stop, :normal, state}
    def handle_info(_message, state), do: {:ok, state}
  end
end
