# Compile-guarded (same as the transport it serves): only defined when the optional :grpc + :protobuf
# deps are present. A consumer without gRPC never adds it to their tree.
if Code.ensure_loaded?(Protobuf) and Code.ensure_loaded?(GRPC.Service) do
  defmodule Arcadic.Transport.Grpc.ChannelPool do
    @moduledoc """
    Caller-supervised shared-channel cache for `Arcadic.Transport.Grpc`.

    A gRPC channel is HTTP/2-multiplexed — many concurrent streams share ONE connection — so this is a
    **shared** channel cache (one long-lived channel per `{host, port, tls?}` endpoint reused across
    ALL calls), NOT an exclusive checkout pool that would serialize streams. It **opt-in**: add

        children = [{Arcadic.Transport.Grpc.ChannelPool, []}]

    to your supervision tree. When it is running, the transport reuses its channel; when it is absent,
    the transport falls back to a fresh per-call connect (no behavior change). Tenant-blind — keyed on
    the endpoint only, carrying no database/scope. See `docs/CHARTER.md` (CA-1) and the transport ADR.

    The cache serializes `checkout` through the GenServer so two concurrent first-connects don't race
    into two channels; a dead channel (its adapter connection process gone) is transparently reconnected.
    """
    use GenServer

    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
    end

    @doc """
    Return a healthy channel for `key`, connecting via `connect_fn` (a 0-arity `-> {:ok, channel} |
    {:error, term}`) and caching it if the endpoint has no live channel yet.
    """
    @spec checkout(term(), (-> {:ok, term()} | {:error, term()})) ::
            {:ok, term()} | {:error, term()}
    def checkout(key, connect_fn) when is_function(connect_fn, 0) do
      GenServer.call(__MODULE__, {:checkout, key, connect_fn})
    end

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def handle_call({:checkout, key, connect_fn}, _from, channels) do
      case Map.get(channels, key) do
        nil ->
          reconnect(key, connect_fn, channels)

        ch ->
          if alive?(ch),
            do: {:reply, {:ok, ch}, channels},
            else: reconnect(key, connect_fn, channels)
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

    defp safe_disconnect(ch) do
      _ = GRPC.Stub.disconnect(ch)
      :ok
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    defp reconnect(key, connect_fn, channels) do
      case connect_fn.() do
        {:ok, ch} ->
          # Best-effort-disconnect the stale channel being replaced: grpc 1.x owns each
          # connection process under its own GRPC.Client.Supervisor (random make_ref name),
          # so dropping the handle without disconnecting would orphan that connection tree —
          # socket and resolver — there forever.
          case Map.get(channels, key) do
            nil -> :ok
            stale -> safe_disconnect(stale)
          end

          {:reply, {:ok, ch}, Map.put(channels, key, ch)}

        {:error, _} = err ->
          {:reply, err, Map.delete(channels, key)}
      end
    end

    # A channel is alive iff its underlying adapter connection process is alive (mint under grpc 1.x).
    defp alive?(%{adapter_payload: %{conn_pid: pid}}) when is_pid(pid), do: Process.alive?(pid)
    defp alive?(_), do: false
  end
end
