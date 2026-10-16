# Compile-guarded (same as the transport it serves): only defined when the optional :grpc + :protobuf
# deps are present. A consumer without gRPC never adds it to their tree.
if Code.ensure_loaded?(Protobuf) and Code.ensure_loaded?(GRPC.Service) do
  defmodule Arcadic.Transport.Grpc.ChannelPool do
    @moduledoc """
    Caller-supervised shared-channel cache for `Arcadic.Transport.Grpc`.

    A gRPC channel is HTTP/2-multiplexed — many concurrent streams share ONE connection — so this is a
    **shared** channel cache (one long-lived channel per `{host, port, tls?, trust-selection}` endpoint
    reused across ALL calls with the SAME trust config), NOT an exclusive checkout pool that would
    serialize streams. It **opt-in**: add

        children = [{Arcadic.Transport.Grpc.ChannelPool, []}]

    to your supervision tree. When it is running, the transport reuses its channel; when it is absent,
    the transport falls back to a fresh per-call connect (no behavior change). Tenant-blind — keyed on
    the endpoint + trust selection only, carrying no database/scope. Rationale for the process: a live
    gRPC channel is a socket/connection process (`adapter_payload.conn_pid`), not an immutable value
    copied into a pure-data `Conn` — sharing one requires a process, which is why the pool is opt-in
    and caller-supervised rather than transport-internal.

    The CONNECT itself runs in the CALLER's process, never inside the GenServer: a connect can block
    for the adapter's full connect timeout (grpc 1.x default 15s, ×2 with the transport's transient
    retry), and serializing that inside the pool would queue every OTHER endpoint's checkout behind
    one dead endpoint. The GenServer only makes two O(1) decisions — a cache lookup, and a
    first-wins register when two concurrent first-connects race (the loser's channel serves its own
    call and is then best-effort disconnected). A dead channel (its adapter connection process gone)
    is transparently replaced on the next checkout.
    """

    use GenServer

    # Both server operations are O(1) map touches; the explicit timeout documents that no caller
    # ever waits behind a connect here (the pre-restructure design ran connect_fn inside
    # handle_call, where one dead endpoint could hold every checkout past this deadline).
    @call_timeout 5_000

    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts) do
      # The transport resolves the pool by its OWN name (Process.whereis/checkout), so a custom
      # :name would silently run a pool nobody uses — reject it value-free instead.
      if opts[:name] not in [nil, __MODULE__] do
        raise ArgumentError,
              "ChannelPool does not support a custom :name (the transport resolves it by module name)"
      end

      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end

    @doc """
    Return a healthy channel for `key`, connecting via `connect_fn` (a 0-arity `-> {:ok, channel} |
    {:error, term}`) and caching it if the endpoint has no live channel yet. The connect runs in the
    CALLER process; concurrent first-connects race and the first registered channel wins.
    """
    @spec checkout(term(), (-> {:ok, term()} | {:error, term()})) ::
            {:ok, term()} | {:error, term()}
    def checkout(key, connect_fn) when is_function(connect_fn, 0) do
      case GenServer.call(__MODULE__, {:lookup, key}, @call_timeout) do
        {:ok, ch} ->
          {:ok, ch}

        :connect ->
          case connect_fn.() do
            {:ok, ch} -> register(key, ch)
            {:error, _} = err -> err
          end
      end
    end

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def handle_call({:lookup, key}, _from, channels) do
      case Map.get(channels, key) do
        nil -> {:reply, :connect, channels}
        ch -> if alive?(ch), do: {:reply, {:ok, ch}, channels}, else: {:reply, :connect, channels}
      end
    end

    def handle_call({:register, key, ch}, _from, channels) do
      case Map.get(channels, key) do
        nil ->
          {:reply, :stored, Map.put(channels, key, ch)}

        existing ->
          if alive?(existing) do
            # Lost the first-connect race: the winner is already shared; disconnect ours
            # asynchronously — a disconnect is itself a synchronous GenServer.call into the
            # grpc connection manager, and the pool must never block a reply on teardown.
            async_disconnect(ch)
            {:reply, {:ok, existing}, channels}
          else
            async_disconnect(existing)
            {:reply, :stored, Map.put(channels, key, ch)}
          end
      end
    end

    # On shutdown, disconnect every cached channel — best-effort. grpc 1.x owns each
    # connection process under its own GRPC.Client.Supervisor, so a channel that cannot be
    # disconnected here (already dead, mid-teardown race) is left to that supervisor / app
    # shutdown; one such channel must not abort the rest of the pool's shutdown.
    @impl true
    def terminate(_reason, channels) do
      Enum.each(channels, fn {_key, ch} -> safe_disconnect(ch) end)
      :ok
    end

    defp register(key, ch) do
      GenServer.call(__MODULE__, {:register, key, ch}, @call_timeout)
      |> case do
        :stored -> {:ok, ch}
        {:ok, _winner} = ok -> ok
      end
    catch
      # The pool stopped between the caller's connect and this registration: nobody owns the
      # cache entry anymore, so the freshly opened channel is OURS to disconnect — never let
      # its supervisor-owned connection tree be orphaned. The caller gets a typed error.
      :exit, _ ->
        safe_disconnect(ch)
        {:error, :pool_stopped}
    end

    defp safe_disconnect(ch) do
      _ = GRPC.Stub.disconnect(ch)
      :ok
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    defp async_disconnect(ch) do
      _ = Task.start(fn -> safe_disconnect(ch) end)
      :ok
    end

    # A channel is alive iff its underlying adapter connection process is alive (mint under grpc 1.x).
    defp alive?(%{adapter_payload: %{conn_pid: pid}}) when is_pid(pid), do: Process.alive?(pid)
    defp alive?(_), do: false
  end
end
