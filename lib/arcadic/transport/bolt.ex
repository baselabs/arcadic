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
    (which encodes the ArcadeDB-correct defaults — Bolt v4 pin, and the plaintext
    `bolt` scheme by default; pass `scheme: "bolt+s"` for TLS, see below) and passes
    it as `transport_options: [bolt: conn_ref]`.

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

    > **Never enable boltx debug logging against arcadic.** `config :boltx, log: true`
    > (or `:log_hex`) makes boltx debug-log the full HELLO payload — including the auth
    > `credentials` (the password). arcadic drives the HELLO itself and never enables
    > this; keep it off so a credential cannot reach a log line (Critical Rule 3).
    """

    @behaviour Arcadic.Transport

    alias Arcadic.{Conn, Error, Telemetry, TransportError}
    alias Boltx.BoltProtocol.Message.{HelloMessage, PullMessage, RunMessage}
    alias Boltx.BoltProtocol.Versions
    alias Boltx.Client
    alias Boltx.Types.{Duration, Point}

    import Boltx.BoltProtocol.ServerResponse, only: [statement_result: 1, pull_result: 2]

    # Local struct-shape aliases for boltx's structs. boltx defines the structs via
    # `defstruct` but exports NO `@type t`, so `Boltx.Connection.t()` fails dialyzer as
    # `unknown_type`; and a bare `%Boltx.Connection{}` in an `@spec` trips credo's
    # SpecWithStruct check. Naming the struct shapes as local types once satisfies both:
    # dialyzer resolves the struct, credo sees a type-name call (no struct literal) in specs.
    @typep boltx_conn :: %Boltx.Connection{}
    @typep boltx_error :: %Boltx.Error{}
    @typep boltx_client :: %Client{}
    @typep boltx_config :: %Client.Config{}

    @rollback_throw :arcadic_rollback

    @doc """
    Start a boltx connection with ArcadeDB-correct defaults. Opts: `:hostname`,
    `:port` (default 7687), `:username`, `:password`, `:scheme`, `:ssl_opts`, plus most
    boltx options (`:uri` is rejected — arcadic must own the scheme, see `:scheme` below).
    Pins Bolt to v4 (ArcadeDB speaks v4; boltx defaults to v5 → version_negotiation_error).

    ## Transport security (`:scheme`)

    - `"bolt"` (default) — plaintext. ArcadeDB's Bolt is plaintext unless the server is
      configured with `arcadedb.bolt.ssl` + a keystore.
    - `"bolt+s"` — TLS, **secure by default**: the server certificate is verified against the
      OS trust store (`verify_peer`). Pass `ssl_opts: [cacertfile: "/path/ca.pem"]` to trust a
      private CA. To opt out of verification, pass `ssl_opts: [verify: :verify_none]` explicitly
      — this encrypts but does NOT authenticate the peer (MITM-able: an attacker on the Bolt
      path can present any certificate and every param/row flows to it), so it is a deliberate
      caller opt-in, never a silent default.

    > boltx's own scheme→verify mapping is INVERTED (its `bolt+s` forces `verify_none`), so
    > arcadic translates `"bolt+s"` to boltx's `"bolt+ssc"` to get `verify_peer`. Callers use
    > only `"bolt"` / `"bolt+s"`; `"bolt+ssc"` is not a caller scheme.
    """
    @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
    def start_link(opts),
      do: DBConnection.start_link(Arcadic.Transport.Bolt.Connection, resolve_opts(opts))

    @doc """
    Start a Bolt pool AND return the `transport_options` for a Conn in one call, so
    the pool (`:bolt`, for execute/transaction/ready?) and the per-stream connect opts
    (`:bolt_opts`, for query_stream) cannot drift to different hosts/credentials. Accepts
    the same opts as `start_link/1`, including `:scheme` / `:ssl_opts` for TLS (see there).

        {:ok, topts} = Arcadic.Transport.Bolt.setup(hostname: h, port: p, username: "root", password: pw)
        conn = Arcadic.connect(url, db, auth: {"root", pw}, transport: Arcadic.Transport.Bolt, transport_options: topts)

        # TLS, verify_peer against a private CA:
        {:ok, topts} = Arcadic.Transport.Bolt.setup(scheme: "bolt+s", ssl_opts: [cacertfile: "/ca.pem"], hostname: h, port: p, username: "root", password: pw)
    """
    @spec setup(keyword()) :: {:ok, keyword()} | {:error, term()}
    def setup(opts) do
      resolved = resolve_opts(opts)

      with {:ok, pool} <- DBConnection.start_link(Arcadic.Transport.Bolt.Connection, resolved) do
        {:ok, [bolt: pool, bolt_opts: resolved]}
      end
    end

    # arcadic exposes "bolt" (plaintext) | "bolt+s" (TLS, secure by default).
    @schemes ~w(bolt bolt+s)

    @doc false
    @spec resolve_opts(keyword()) :: keyword()
    def resolve_opts(opts) do
      {username, opts} = Keyword.pop(opts, :username)
      {password, opts} = Keyword.pop(opts, :password)
      scheme = Keyword.get(opts, :scheme, "bolt")

      unless scheme in @schemes do
        raise ArgumentError, "bolt scheme must be one of #{inspect(@schemes)} (\"bolt+s\" = TLS)"
      end

      # A caller `:uri` carries its own scheme, and boltx's Client.Config PREFERS the parsed-uri
      # scheme over the `:scheme` opt — so a `"bolt+s://"` uri would sail past the @schemes check
      # AND put_transport_scheme/2, letting boltx open TLS with its own verify_none default. arcadic
      # OWNS the scheme translation (the whole point of B8's secure default), so reject :uri outright.
      if Keyword.has_key?(opts, :uri) do
        raise ArgumentError,
              "bolt :uri is not supported (it bypasses arcadic's TLS scheme translation); " <>
                "use :scheme + :hostname + :port"
      end

      [versions: [4.4, 4.3, 4.2, 4.1], pool_size: 1]
      |> Keyword.merge(opts)
      |> put_transport_scheme(scheme)
      |> Keyword.put(:auth, username: username, password: password)
    end

    # boltx's scheme→verify mapping is INVERTED from the Neo4j convention: its "bolt+s" FORCES
    # verify_none and its "bolt+ssc" FORCES verify_peer (client.ex:80-81 — `Keyword.merge(ssl_opts,
    # verify: …)` puts the forced value LAST, so it overrides any caller verify). So arcadic
    # TRANSLATES its own "bolt+s" to the boltx scheme that yields the requested verification:
    #   secure (verify_peer, the default)  → boltx "bolt+ssc"  (+ OS cacerts unless caller gave a CA)
    #   explicit verify_none (caller opt-in) → boltx "bolt+s"
    # An omitted scheme is EXPLICIT "bolt" — never delegated to boltx's own "bolt+s"/verify_none default.
    defp put_transport_scheme(opts, "bolt"), do: Keyword.put(opts, :scheme, "bolt")

    defp put_transport_scheme(opts, "bolt+s") do
      ssl_opts = Keyword.get(opts, :ssl_opts, [])

      if Keyword.get(ssl_opts, :verify) == :verify_none do
        Keyword.put(opts, :scheme, "bolt+s")
      else
        cacert_opts =
          if Keyword.has_key?(ssl_opts, :cacerts) or Keyword.has_key?(ssl_opts, :cacertfile),
            do: ssl_opts,
            else: Keyword.put(ssl_opts, :cacerts, :public_key.cacerts_get())

        opts |> Keyword.put(:scheme, "bolt+ssc") |> Keyword.put(:ssl_opts, cacert_opts)
      end
    end

    @impl true
    def execute(%Conn{} = conn, _mode, %{statement: statement, params: params}, _opts) do
      query = %Boltx.Query{statement: statement, extra: run_extra(conn)}

      case DBConnection.prepare_execute(bolt(conn), query, format_params(params), []) do
        {:ok, _query, %Boltx.Response{results: results}} -> {:ok, results}
        {:error, %Boltx.Error{} = e} -> {:error, bolt_error(e)}
        {:error, other} -> {:error, %TransportError{reason: transport_reason(other)}}
      end
    end

    # The `db` extra selects the ArcadeDB database per RUN/BEGIN (Boltx's RunMessage
    # defaults mode to "w" — kept statement-agnostic). Shared by execute, transaction,
    # and query_stream so conn.database is honored uniformly across Bolt ops.
    @doc false
    @spec run_extra(Conn.t()) :: %{db: String.t()}
    def run_extra(%Conn{database: database}), do: %{db: database}

    # The cursor callbacks (Bolt.Connection.handle_declare) receive the DBConnection
    # query term, which is either a %Boltx.Query{} (built by the in-tx query_stream/3
    # clause) or a bare statement string; extract the statement uniformly.
    @doc false
    @spec statement_of(term()) :: String.t()
    def statement_of(%Boltx.Query{statement: s}), do: s
    def statement_of(s) when is_binary(s), do: s

    # Mirror Boltx.query/4's param formatting so a Duration/Point param binds
    # identically whether it goes through execute or the low-level stream path.
    @doc false
    @spec format_params(map()) :: map()
    def format_params(params) do
      params
      |> Enum.map(&format_param/1)
      |> Enum.map(fn {k, {:ok, value}} -> {k, value} end)
      |> Map.new()
    end

    defp format_param({name, %Duration{} = d}),
      do: {name, Duration.format_param(d)}

    defp format_param({name, %Point{} = p}),
      do: {name, Point.format_param(p)}

    defp format_param({name, value}), do: {name, {:ok, value}}

    @impl true
    def query_stream(%Conn{session_id: sid} = conn, %{statement: statement, params: params}, opts)
        when is_binary(sid) do
      tx_ref =
        conn.transport_options[:bolt] ||
          raise ArgumentError, "in-transaction Bolt streaming requires the transaction conn"

      query = %Boltx.Query{statement: statement}

      stream =
        DBConnection.stream(tx_ref, query, format_params(params),
          chunk_size: Keyword.get(opts, :chunk_size, 1000),
          timeout: Keyword.get(opts, :timeout, :infinity),
          run_extra: run_extra(conn)
        )
        |> Stream.flat_map(& &1)
        |> with_stream_telemetry()

      {:ok, stream}
    end

    def query_stream(%Conn{} = conn, %{statement: statement, params: params}, opts) do
      case conn.transport_options[:bolt_opts] do
        nil ->
          {:error,
           %Error{
             reason: :not_supported,
             message: "bolt streaming requires transport_options[:bolt_opts]"
           }}

        bolt_opts ->
          chunk = Keyword.get(opts, :chunk_size, 1000)
          timeout = Keyword.get(opts, :timeout, :infinity)
          {:ok, build_stream(conn, bolt_opts, statement, format_params(params), chunk, timeout)}
      end
    end

    # Emit the same value-free `[:arcadic, :query_stream, :start|:stop]` pair the HTTP and non-tx
    # Bolt stream paths emit (spec §6 / decision 15), so the tx-scoped stream is observable too.
    # `DBConnection.stream` owns the enumeration, so bracket it with `Stream.transform` (start on
    # first demand, stop on end/halt) counting rows. Unlike the `Stream.resource` paths, the
    # transform's last-fun cannot distinguish drained-vs-halted, so `reason` is `:ok` on any end.
    defp with_stream_telemetry(stream) do
      Stream.transform(
        stream,
        fn ->
          Telemetry.event([:arcadic, :query_stream, :start], %{}, %{mode: :read})
          0
        end,
        fn row, count -> {[row], count + 1} end,
        fn count ->
          Telemetry.event([:arcadic, :query_stream, :stop], %{row_count: count}, %{
            mode: :read,
            reason: :ok
          })
        end
      )
    end

    # A dedicated raw connection per stream (the pool's DBConnection cursor callbacks
    # are non-functional stubs, so it cannot page). Stream.resource guarantees the
    # after-fun runs on normal end, early halt, and error; the BEAM reaps the
    # enumerator-owned socket on an untrappable :kill.
    defp build_stream(conn, bolt_opts, statement, params, chunk, timeout) do
      Stream.resource(
        fn -> stream_start(conn, bolt_opts, statement, params, timeout) end,
        fn acc -> stream_next(acc, chunk, timeout) end,
        fn acc -> stream_stop(acc) end
      )
    end

    defp stream_start(conn, bolt_opts, statement, params, timeout) do
      case leak_safe_connect(bolt_opts) do
        {:ok, state} ->
          case stream_run(state.client, statement, params, run_extra(conn), timeout) do
            {:ok, run_success} ->
              Telemetry.event([:arcadic, :query_stream, :start], %{}, %{mode: :read})
              %{state: state, run: run_success, rows: 0, done: false, first: true}

            {:error, reason} ->
              # after-fun does NOT run for a start-fun raise — tear down here first.
              _ = Boltx.Connection.disconnect(:normal, state)
              raise stream_error(reason)
          end

        {:error, reason} ->
          # A failed connect leaks no socket: leak_safe_connect/1 owns the handle from
          # Client.do_connect onward and safe_disconnects it before returning {:error, _}.
          # Raise a REDACTED typed error (never the raw exception, which could embed
          # server bytes — Rule 3); the reason type is preserved (%Boltx.Error{}/atom).
          raise stream_error(reason)
      end
    end

    # arcadic owns the per-stream (and pool) connect: drive boltx's public connect
    # primitives directly so it holds the :gen_tcp socket handle from the moment
    # Client.do_connect opens it and closes it on EVERY failure. This closes the
    # connect-time fd leak that Boltx.Connection.connect/Boltx.Client.connect exhibit
    # (auth-reject {:error} and non-Bolt-endpoint raise both discard the socket without
    # closing it). Spec uses the local boltx_* struct-shape types (see their @typep note).
    @doc false
    @spec leak_safe_connect(keyword()) ::
            {:ok, boltx_conn()} | {:error, boltx_error() | atom()}
    def leak_safe_connect(bolt_opts) do
      config = Client.Config.new(bolt_opts)

      case Client.do_connect(config) do
        {:error, reason} ->
          # refused/timeout: no socket opened, nothing to leak.
          {:error, reason}

        {:ok, client} ->
          # arcadic now OWNS the socket; guarantee close on every subsequent outcome.
          try do
            with {:ok, client} <- handshake(client, config),
                 :ok <- assert_v4_band(client.bolt_version),
                 {:ok, meta} <- hello_bounded(client, bolt_opts, config.connect_timeout) do
              {:ok, build_state(meta, client)}
            else
              # preserve the reason (never flatten %Boltx.Error{} to an atom).
              {:error, reason} ->
                _ = safe_disconnect(client)
                {:error, reason}
            end
          rescue
            # unexpected internal defect: clean up then fail loud — do not launder.
            e ->
              _ = safe_disconnect(client)
              reraise e, __STACKTRACE__
          end
      end
    end

    # Exact 4-byte handshake read. A connect timeout is preserved as :timeout; non-version
    # reply bytes are dropped by the `_` match (information-destroying — Rule 3: they could
    # be a misdirected HTTP/auth-proxy body, so nothing but a value-free atom is returned),
    # and no FunctionClauseError can escape (unlike Boltx.Client.decode_version/1).
    @spec handshake(boltx_client(), boltx_config()) ::
            {:ok, boltx_client()}
            | {:error, :version_negotiation_error | :bolt_protocol_error | :timeout}
    defp handshake(client, config) do
      data =
        <<0x60, 0x60, 0xB0, 0x17>> <>
          (config.versions
           |> Enum.sort(&>=/2)
           |> Enum.map_join("", &Versions.to_bytes/1))

      with :ok <- Client.send_packet(client, data) do
        case Client.recv_data(client, config.connect_timeout, 4) do
          {:ok, <<0, 0, minor, major>>} when major > 0 ->
            {:ok, %{client | bolt_version: Float.round(major + minor / 10.0, 1)}}

          {:ok, _} ->
            {:error, :version_negotiation_error}

          {:error, :timeout} ->
            {:error, :timeout}

          {:error, _} ->
            {:error, :bolt_protocol_error}
        end
      end
    end

    # Bounded HELLO — mirrors the RUN/PULL frame-exchange pattern (Decision 17) so the
    # HELLO leg is bounded by connect_timeout instead of boltx's hardcoded :infinity recv.
    @spec hello_bounded(boltx_client(), keyword(), timeout()) ::
            {:ok, map()} | {:error, boltx_error() | atom()}
    defp hello_bounded(client, bolt_opts, timeout) do
      payload = HelloMessage.encode(client.bolt_version, bolt_opts)

      with :ok <- Client.send_packet(client, payload) do
        recv_hello(client, timeout)
      end
    end

    # The HELLO response is the one connect leg where server-controlled bytes flow through
    # boltx's parser. prepare_generic_messages RAISES (e.g. CaseClauseError) on an
    # unrecognized message, and that raise carries the server payload in its term — a Rule 3
    # leak if it rode the caller's raise (stream) or the connection crash log (pool). Redact
    # any parse raise to a value-free typed reason. The top-level rescue in leak_safe_connect
    # still fails loud on genuine code-shape defects (encode/send arity drift); the live
    # path-C test stays the boltx-bump tripwire (it asserts :unauthorized specifically). A
    # FAILURE reply and a timeout are {:error, _} returns (not raises), so they pass through.
    @spec recv_hello(boltx_client(), timeout()) :: {:ok, map()} | {:error, boltx_error() | atom()}
    defp recv_hello(client, timeout) do
      Client.recv_packets(client, &Client.prepare_generic_messages/2, timeout)
    rescue
      _ -> {:error, :bolt_protocol_error}
    end

    # arcadic pins Bolt v4 ([4.4, 4.3, 4.2, 4.1]); the HELLO-only auth band is [3.0, 5.1).
    # Reject outside it rather than under-authenticate a 5.1+ peer that needs a separate LOGON.
    @spec assert_v4_band(term()) :: :ok | {:error, :version_negotiation_error}
    defp assert_v4_band(v) when is_float(v) and v >= 3.0 and v < 5.1, do: :ok
    defp assert_v4_band(_), do: {:error, :version_negotiation_error}

    # Cleanup must not mask the original error/raise: Client.disconnect/1 destructures
    # client.sock and calls close, which raises if the socket is already gone — swallow it.
    @spec safe_disconnect(boltx_client()) :: :ok
    defp safe_disconnect(client) do
      Client.disconnect(client)
    rescue
      _ -> :ok
    end

    # Populate %Boltx.Connection{} from the HELLO reply (mirror boltx's
    # get_server_metadata_state/1) so a consumer of server_version/connection_id/hints/
    # patch_bolt reads real metadata, not nil.
    @spec build_state(map(), boltx_client()) :: boltx_conn()
    defp build_state(meta, client) do
      %Boltx.Connection{
        client: client,
        server_version: meta["server"],
        connection_id: meta["connection_id"] || "",
        hints: meta["hints"] || "",
        patch_bolt: meta["patch_bolt"] || ""
      }
    end

    defp stream_next(%{done: true} = acc, _chunk, _timeout), do: {:halt, acc}

    defp stream_next(%{state: state, run: run, first: first} = acc, chunk, timeout) do
      case stream_pull(state.client, %{n: chunk}, timeout) do
        {:ok, pull} ->
          success_data = pull_result(pull, :success_data)
          assert_has_more_key!(success_data, first)
          rows = Boltx.Response.new(statement_result(result_run: run, result_pull: pull)).results
          acc = %{acc | rows: acc.rows + length(rows), first: false}

          if Map.get(success_data, "has_more", false),
            do: {rows, acc},
            else: {rows, %{acc | done: true}}

        {:error, reason} ->
          raise stream_error(reason)
      end
    end

    defp stream_stop(%{state: state, rows: rows, done: done}) do
      # A lazy Stream.resource after-fun cannot observe WHY enumeration ended, so the
      # reason distinguishes only "drained" (:ok) from "stopped early/error" (:halted).
      reason = if done, do: :ok, else: :halted

      Telemetry.event([:arcadic, :query_stream, :stop], %{row_count: rows}, %{
        mode: :read,
        reason: reason
      })

      _ = Boltx.Connection.disconnect(:normal, state)
      :ok
    end

    # boltx's send_run/send_pull hardcode an :infinity recv; reimplement the frame exchange so
    # `timeout` bounds each RUN and PULL (default :infinity). Same return shapes as
    # Client.send_run/send_pull. Public @doc false so BOTH stream sites — the non-tx Stream.resource
    # (stream_start/stream_next) AND the in-tx cursor callbacks (Connection.handle_declare/handle_fetch)
    # — share ONE frame-encoding site (the precedent set by statement_of/1, format_params/1,
    # stream_error/1, assert_has_more_key!/2).
    @doc false
    @spec stream_run(boltx_client(), String.t(), map(), map(), timeout()) ::
            {:ok, term()} | {:error, term()}
    def stream_run(client, statement, params, extra, timeout) do
      payload = RunMessage.encode(client.bolt_version, statement, params, extra)

      with :ok <- Client.send_packet(client, payload) do
        Client.recv_packets(client, &RunMessage.prepare_messages/2, timeout)
      end
    end

    @doc false
    @spec stream_pull(boltx_client(), map(), timeout()) :: {:ok, term()} | {:error, term()}
    def stream_pull(client, extra, timeout) do
      payload = PullMessage.encode(client.bolt_version, extra)

      with :ok <- Client.send_packet(client, payload) do
        Client.recv_packets(client, &PullMessage.prepare_messages/2, timeout)
      end
    end

    # `has_more` is a raw server SUCCESS key (not a boltx symbol). Assert its presence
    # on the first chunk so a driver/server drift fails LOUD instead of silently
    # truncating every stream to its first chunk.
    @doc false
    @spec assert_has_more_key!(map(), boolean()) :: :ok | nil
    def assert_has_more_key!(success_data, true) do
      unless Map.has_key?(success_data, "has_more") do
        raise %TransportError{reason: :bolt_protocol_error}
      end
    end

    def assert_has_more_key!(_success_data, false), do: :ok

    # Mid-stream errors reuse bolt_error/1 so no row/param bytes leak into the raised
    # exception's message or inspect (Critical Rule 3). A finite-timeout breach arrives
    # as %Boltx.Error{code: :timeout} → :timeout; a socket-level send failure is a bare
    # atom (e.g. :closed) — both handled before the struct fallback. Public (@doc false)
    # so the mapping — including the value-redaction and timeout invariants — is unit-
    # testable server-free (mirrors map_transaction_outcome/1, assert_has_more_key!/2).
    @doc false
    @spec stream_error(term()) :: Error.t() | TransportError.t()
    def stream_error(%Boltx.Error{code: :timeout}), do: %TransportError{reason: :timeout}
    def stream_error(%Boltx.Error{} = e), do: bolt_error(e)
    def stream_error(reason) when is_atom(reason), do: %TransportError{reason: reason}
    def stream_error(other), do: %TransportError{reason: transport_reason(other)}

    @impl true
    def transaction(%Conn{} = conn, fun, _opts) when is_function(fun, 1) do
      # `Boltx.transaction/4` is a thin wrapper over `DBConnection.transaction/3`
      # (and `Boltx.rollback/2` over `DBConnection.rollback/2`). We call DBConnection
      # directly: boltx's wrapper carries a spurious `no_return` success typing that
      # dialyzer propagates to every caller, whereas the underlying DBConnection
      # functions are typed cleanly. `extra_parameters: run_extra(conn)` threads
      # `db: conn.database` into BEGIN so the tx targets the right ArcadeDB database.
      outcome =
        DBConnection.transaction(
          bolt(conn),
          fn tx_ref ->
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
          end,
          extra_parameters: run_extra(conn)
        )

      map_transaction_outcome(outcome)
    end

    # Typed, value-free mapping of the DBConnection.transaction outcome. The bare
    # `:rollback` atom is DBConnection's commit-failure signal (F6) — never leak it;
    # any other unexpected term becomes a value-free transport error, never a raw
    # passthrough (the passthrough is the exact leak F6 closes).
    @doc false
    @spec map_transaction_outcome(term()) :: {:ok, term()} | {:error, term()}
    def map_transaction_outcome({:ok, result}), do: {:ok, result}
    def map_transaction_outcome({:error, {:arcadic_rollback, reason}}), do: {:error, reason}
    def map_transaction_outcome({:error, %Boltx.Error{} = e}), do: {:error, bolt_error(e)}

    def map_transaction_outcome({:error, :rollback}),
      do: {:error, %Error{reason: :transaction_error, message: "bolt transaction commit failed"}}

    def map_transaction_outcome({:error, _other}),
      do: {:error, %TransportError{reason: :transaction_error}}

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
