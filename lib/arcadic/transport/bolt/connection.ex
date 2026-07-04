# Guarded on Boltx so this compiles only when the optional boltx dep is present:
# the `defdelegate` targets `Boltx.Connection`, which must exist to resolve.
if Code.ensure_loaded?(Boltx) do
  defmodule Arcadic.Transport.Bolt.Connection do
    @moduledoc false
    use DBConnection

    alias Arcadic.Transport.Bolt
    alias Arcadic.TransportError

    # Inject the leak-safe connect; delegate every other DBConnection callback to
    # boltx unchanged. leak_safe_connect/1 returns a %Boltx.Error{} (already an
    # Exception) or a bare structural atom; DBConnection requires an Exception, so
    # the atom is normalized into %TransportError{} carrying ONLY that atom (Rule 3).
    @impl true
    def connect(opts) do
      case Bolt.leak_safe_connect(opts) do
        {:ok, state} -> {:ok, state}
        {:error, %Boltx.Error{} = e} -> {:error, e}
        {:error, reason} -> {:error, %TransportError{reason: reason}}
      end
    end

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
    defdelegate handle_execute(query, params, opts, state), to: Boltx.Connection

    @impl true
    defdelegate handle_prepare(query, opts, state), to: Boltx.Connection

    @impl true
    defdelegate handle_close(query, opts, state), to: Boltx.Connection

    @impl true
    defdelegate handle_declare(query, params, opts, state), to: Boltx.Connection

    @impl true
    defdelegate handle_fetch(query, cursor, opts, state), to: Boltx.Connection

    @impl true
    defdelegate handle_deallocate(query, cursor, opts, state), to: Boltx.Connection

    @impl true
    defdelegate handle_status(opts, state), to: Boltx.Connection
  end
end
