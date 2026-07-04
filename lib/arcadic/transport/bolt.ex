# `boltx` is an OPTIONAL dependency. This module hard-expands `%Boltx.Response{}` /
# `%Boltx.Error{}` structs (compile-time) and calls `DBConnection`/`Boltx`, so it is
# only defined when boltx is actually present. Guarding it here keeps boltx truly
# optional: a downstream consumer that does not depend on boltx still compiles
# arcadic (the default HTTP transport never needs it). Verified: without this guard,
# `%Boltx.Response{}` fails to compile with "Boltx.Response.__struct__/1 is undefined".
if Code.ensure_loaded?(Boltx) do
  defmodule Arcadic.Transport.Bolt do
    @moduledoc """
    Bolt transport for ArcadeDB via the `boltx` driver (Bolt v4). Verified interop
    (spec §15 P19/P20). The consumer starts a Bolt connection with `start_link/1`
    (which encodes the ArcadeDB-correct defaults — Bolt v4 pin, non-TLS scheme) and
    passes it as `transport_options: [bolt: conn_ref]`.

    Supports the query hot path (`execute/4`), native fun-based transactions
    (`transaction/3`), and a `RETURN 1` health check (`ready?/1`). Server admin
    (create/drop/list database) is an HTTP/server operation, not a Bolt one — those
    callbacks return `{:error, %Arcadic.Error{reason: :not_supported}}`; use an HTTP
    conn for admin.

    > **Read/write semantics differ from the HTTP transport.** Bolt has no `/query`
    > vs `/command` endpoint split, so `Arcadic.query/4` on a Bolt conn does NOT
    > enforce read-only — the HTTP transport's non-idempotent rejection is the
    > ArcadeDB `/query` endpoint's server-side behavior, which Bolt lacks. arcadic is
    > statement-agnostic by design (params-only; it never parses statement
    > semantics), so a write issued through `query/4` on Bolt executes. Use
    > `command/4` for writes on Bolt.
    """

    @behaviour Arcadic.Transport

    alias Arcadic.{Conn, Error, TransportError}

    @rollback_throw :arcadic_rollback

    @doc """
    Start a boltx connection with ArcadeDB-correct defaults. Opts: `:hostname`,
    `:port` (default 7687), `:username`, `:password`, plus any boltx option. Pins
    Bolt to v4 (ArcadeDB speaks v4; boltx defaults to v5 → version_negotiation_error)
    and uses the non-TLS `bolt` scheme (ArcadeDB Bolt is TLS-disabled by default).
    """
    @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
    def start_link(opts) do
      defaults = [scheme: "bolt", versions: [4.4, 4.3, 4.2, 4.1], pool_size: 1]
      {username, opts} = Keyword.pop(opts, :username)
      {password, opts} = Keyword.pop(opts, :password)

      boltx_opts =
        Keyword.merge(defaults, opts)
        |> Keyword.put(:auth, username: username, password: password)

      Boltx.start_link(boltx_opts)
    end

    @impl true
    def execute(%Conn{} = conn, _mode, %{statement: statement, params: params}, _opts) do
      case Boltx.query(bolt(conn), statement, params) do
        {:ok, %Boltx.Response{results: results}} -> {:ok, results}
        {:error, %Boltx.Error{} = e} -> {:error, bolt_error(e)}
        {:error, other} -> {:error, %TransportError{reason: transport_reason(other)}}
      end
    end

    @impl true
    def transaction(%Conn{} = conn, fun, _opts) when is_function(fun, 1) do
      # `Boltx.transaction/4` is a thin wrapper over `DBConnection.transaction/3`
      # (and `Boltx.rollback/2` over `DBConnection.rollback/2`). We call DBConnection
      # directly: boltx's wrapper carries a spurious `no_return` success typing that
      # dialyzer propagates to every caller, whereas the underlying DBConnection
      # functions are typed cleanly. Runtime semantics are identical.
      outcome =
        DBConnection.transaction(bolt(conn), fn tx_ref ->
          tx = %{
            conn
            | session_id: "bolt",
              transport_options: Keyword.put(conn.transport_options, :bolt, tx_ref)
          }

          try do
            fun.(tx)
          catch
            :throw, {@rollback_throw, reason} ->
              DBConnection.rollback(tx_ref, {:arcadic_rollback, reason})
          end
        end)

      case outcome do
        {:ok, result} -> {:ok, result}
        {:error, {:arcadic_rollback, reason}} -> {:error, reason}
        {:error, %Boltx.Error{} = e} -> {:error, bolt_error(e)}
        {:error, other} -> {:error, other}
      end
    end

    @impl true
    def ready?(%Conn{} = conn) do
      case Boltx.query(bolt(conn), "RETURN 1 AS n") do
        {:ok, %Boltx.Response{}} -> {:ok, true}
        {:error, %Boltx.Error{} = e} -> {:error, %TransportError{reason: e.code || :bolt_error}}
        {:error, other} -> {:error, %TransportError{reason: transport_reason(other)}}
      end
    end

    # Session-based tx and server admin are not Bolt operations.
    @impl true
    def begin(_conn, _opts),
      do: {:error, %Error{reason: :not_supported, message: "Bolt uses fun-based transaction/3"}}

    @impl true
    def commit(_conn), do: {:error, %Error{reason: :not_supported}}
    @impl true
    def rollback(_conn), do: {:error, %Error{reason: :not_supported}}
    @impl true
    def server_command(_conn, _command),
      do: {:error, %Error{reason: :not_supported, message: "database admin is HTTP-only"}}

    @impl true
    def list_databases(_conn),
      do: {:error, %Error{reason: :not_supported, message: "database admin is HTTP-only"}}

    @impl true
    def database_exists?(_conn, _name),
      do: {:error, %Error{reason: :not_supported, message: "database admin is HTTP-only"}}

    defp bolt(%Conn{transport_options: opts}) do
      opts[:bolt] ||
        raise ArgumentError, "Bolt transport requires transport_options: [bolt: conn_ref]"
    end

    # boltx surfaces Neo4j-style status codes; map to the arcadic reason taxonomy.
    defp bolt_error(%Boltx.Error{code: code, bolt: bolt}) do
      reason =
        case code do
          :syntax_error -> :parse_error
          :unauthorized -> :unauthorized
          _ -> :server_error
        end

      %Error{reason: reason, exception: bolt_code(bolt), message: code && Atom.to_string(code)}
    end

    defp bolt_code(%{code: code}), do: code
    defp bolt_code(_), do: nil

    # boltx/db_connection error paths always yield an Exception struct (see
    # DBConnection.prepare_execute/4 :: {:error, Exception.t()}), so the reason is
    # the exception module. A non-struct fallback would be dead code (dialyzer).
    defp transport_reason(%{__struct__: mod}), do: mod
  end
end
