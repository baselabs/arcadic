# Bolt stays optional for HTTP-only consumers.
if Code.ensure_loaded?(DBConnection) do
  defmodule Arcadic.Transport.Bolt do
    @moduledoc """
    Native Bolt v4 transport for ArcadeDB. Verified interop
    (spec §15 P19/P20). Build the `transport_options` with `Arcadic.Transport.Bolt.setup/1`
    — it returns `[bolt: pool, bolt_opts: resolved]`, so both the query hot path (`:bolt`)
    AND `query_stream/4` (`:bolt_opts`) work from one call and cannot drift to different
    hosts/creds. (`start_link/1` returns only the pool ref — use `setup/1` if you also stream.)

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

    alias Arcadic.{Conn, Error, Telemetry, TransportError}
    alias Arcadic.Transport.Bolt.{Client, Connection, Query, Response}

    @rollback_throw :arcadic_rollback

    @doc """
    Start a native Bolt pool. Opts: `:hostname`, `:port` (default 7687),
    `:username`, `:password`, `:scheme`, `:ssl_opts`, `:connect_timeout`,
    `:versions` (Bolt 4.4–4.1), and DBConnection pool options. `:uri` is rejected.


    - `"bolt"` (default) — plaintext. ArcadeDB's Bolt is plaintext unless the server is
      configured with `arcadedb.bolt.ssl` + a keystore.
    - `"bolt+s"` — TLS, **secure by default**: the server certificate is verified against the
      OS trust store (`verify_peer`). Pass `ssl_opts: [cacertfile: "/path/ca.pem"]` to trust a
      private CA. To opt out of verification, pass `ssl_opts: [verify: :verify_none]` explicitly
      — this encrypts but does NOT authenticate the peer (MITM-able: an attacker on the Bolt
      path can present any certificate and every param/row flows to it), so it is a deliberate
      caller opt-in, never a silent default.

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

        {:ok, topts} = Arcadic.Transport.Bolt.setup(scheme: "bolt+s", ssl_opts: [cacertfile: "/ca.pem"], hostname: h, port: p, username: "root", password: pw)
    """
    @spec setup(keyword()) :: {:ok, keyword()} | {:error, term()}
    def setup(opts) do
      resolved = resolve_opts(opts)

      with {:ok, pool} <- DBConnection.start_link(Arcadic.Transport.Bolt.Connection, resolved) do
        {:ok, [bolt: pool, bolt_opts: resolved]}
      end
    end

    @schemes ~w(bolt bolt+s)

    @bolt_env_vars ~w(BOLT_USER BOLT_PWD BOLT_HOST BOLT_TCP_PORT)

    @doc false
    @spec resolve_opts(keyword()) :: keyword()
    def resolve_opts(opts) do
      reject_bolt_env!()
      {username, opts} = Keyword.pop(opts, :username)
      {password, opts} = Keyword.pop(opts, :password)
      scheme = Keyword.get(opts, :scheme, "bolt")

      unless scheme in @schemes do
        raise ArgumentError, "bolt scheme must be one of #{inspect(@schemes)} (\"bolt+s\" = TLS)"
      end

      if Keyword.has_key?(opts, :uri) do
        raise ArgumentError,
              "bolt :uri is not supported; " <>
                "use :scheme + :hostname + :port"
      end

      [versions: [4.4, 4.3, 4.2, 4.1], pool_size: 1]
      |> Keyword.merge(opts)
      |> put_transport_scheme(scheme)
      |> Keyword.put(:auth, username: username, password: password)
    end

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

        opts |> Keyword.put(:scheme, "bolt+s") |> Keyword.put(:ssl_opts, Keyword.put(cacert_opts, :verify, :verify_peer))
      end
    end

    defp reject_bolt_env! do
      case Enum.find(@bolt_env_vars, fn var -> System.get_env(var) != nil end) do
        nil ->
          :ok

        var ->
          raise ArgumentError,
                "the #{var} environment variable is set; unset it and use " <>
                  ":scheme/:hostname/:port/:username/:password explicitly."
      end
    end

    def execute(conn, _, _, _) when not is_struct(conn, Conn),
      do: raise(ArgumentError, "expected an Arcadic.Conn as the first argument")

    @impl true
    def execute(%Conn{} = conn, _mode, %{statement: statement, params: params}, opts) do
      query = %Query{statement: statement, extra: run_extra(conn)}

      case DBConnection.prepare_execute(bolt(conn), query, format_params(params), exec_opts(opts)) do
        {:ok, _query, %Response{} = resp} -> rows_or_use_explain(resp)
        {:error, %Error{} = e} -> {:error, e}
        {:error, other} -> {:error, %TransportError{reason: transport_reason(other)}}
      end
    end

    defp rows_or_use_explain(%Response{plan: nil, profile: nil, results: results}),
      do: {:ok, results}

    defp rows_or_use_explain(%Response{}) do
      {:error,
       %Error{
         reason: :use_explain,
         message:
           "EXPLAIN/PROFILE returns an execution tree, not rows — use Arcadic.explain/4 or Arcadic.profile/4"
       }}
    end

    @impl true
    @spec explain(Conn.t(), Arcadic.Transport.request(), keyword()) ::
            Arcadic.Transport.plan_result()
    def explain(conn, _, _) when not is_struct(conn, Conn),
      do: raise(ArgumentError, "expected an Arcadic.Conn as the first argument")

    def explain(%Conn{} = conn, %{statement: statement, params: params}, opts) do
      query = %Query{statement: statement, extra: run_extra(conn)}

      case DBConnection.prepare_execute(bolt(conn), query, format_params(params), exec_opts(opts)) do
        {:ok, _query, %Response{} = resp} ->
          {:ok, build_plan(resp)}

        {:error, %Error{} = e} ->
          {:error, e}

        {:error, other} ->
          {:error, %TransportError{reason: transport_reason(other)}}
      end
    end

    @doc false
    @spec build_plan(Response.t()) :: %{plan: String.t(), plan_tree: map(), rows: [map()]}
    def build_plan(%Response{} = resp) do
      summary =
        case resp.plan || resp.profile do
          m when is_map(m) -> m
          _ -> %{}
        end

      args = summary["args"]
      repr = if is_map(args), do: args["string-representation"], else: nil
      plan = if is_binary(repr), do: repr, else: ""
      %{plan: plan, plan_tree: summary, rows: resp.results}
    end

    def run_extra(conn) when not is_struct(conn, Conn),
      do: raise(ArgumentError, "expected an Arcadic.Conn as the first argument")

    @doc false
    @spec run_extra(Conn.t()) :: %{db: String.t()}
    def run_extra(%Conn{database: database}), do: %{db: database}

    @doc false
    @spec statement_of(term()) :: String.t()
    def statement_of(%Query{statement: s}), do: s
    def statement_of(s) when is_binary(s), do: s

    @doc false
    @spec format_params(map()) :: map()
    def format_params(params), do: params

    def query_stream(conn, _, _) when not is_struct(conn, Conn),
      do: raise(ArgumentError, "expected an Arcadic.Conn as the first argument")

    @impl true
    def query_stream(%Conn{session_id: sid} = conn, %{statement: statement, params: params}, opts)
        when is_binary(sid) do
      tx_ref =
        conn.transport_options[:bolt] ||
          raise ArgumentError, "in-transaction Bolt streaming requires the transaction conn"

      query = %Query{statement: statement}

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
              _ = Connection.disconnect(:normal, state)
              raise stream_error(reason)
          end

        {:error, reason} ->
          raise stream_error(reason)
      end
    end

    @doc false
    @spec leak_safe_connect(keyword()) :: {:ok, map()} | {:error, Error.t() | TransportError.t() | atom()}
    def leak_safe_connect(bolt_opts) do
      reject_bolt_env!()
      Client.connect(bolt_opts)
    end

    defp stream_next(%{done: true} = acc, _chunk, _timeout), do: {:halt, acc}

    defp stream_next(%{state: state, run: run, first: first} = acc, chunk, timeout) do
      case stream_pull(state.client, %{n: chunk}, timeout) do
        {:ok, pull} ->
          success_data = pull.success
          assert_has_more_key!(success_data, first)
          rows = response_rows!(run, pull)
          acc = %{acc | rows: acc.rows + length(rows), first: false}

          if Map.get(success_data, "has_more", false),
            do: {rows, acc},
            else: {rows, %{acc | done: true}}

        {:error, reason} ->
          raise stream_error(reason)
      end
    end

    defp stream_stop(%{state: state, rows: rows, done: done}) do
      reason = if done, do: :ok, else: :halted

      Telemetry.event([:arcadic, :query_stream, :stop], %{row_count: rows}, %{
        mode: :read,
        reason: reason
      })

      _ = Connection.disconnect(:normal, state)
      :ok
    end

    @doc false
    @spec stream_run(Client.t(), String.t(), map(), map(), timeout()) :: {:ok, map()} | {:error, term()}
    def stream_run(client, statement, params, extra, timeout),
      do: Client.request(client, :run, [statement, params, Map.put_new(extra, :mode, "w")], timeout)

    @doc false
    @spec stream_pull(Client.t(), map(), timeout()) :: {:ok, map()} | {:error, term()}
    def stream_pull(client, extra, timeout), do: Client.request(client, :pull, [extra], timeout)

    defp response_rows!(run, pull) do
      case Response.new(run, pull) do
        {:ok, response} -> response.results
        {:error, e} -> raise e
      end
    end

    @doc false
    @spec assert_has_more_key!(map(), boolean()) :: :ok | nil
    def assert_has_more_key!(success_data, true) do
      unless Map.has_key?(success_data, "has_more") do
        raise %TransportError{reason: :bolt_protocol_error}
      end
    end

    def assert_has_more_key!(_success_data, false), do: :ok

    @doc false
    @spec stream_error(term()) :: Error.t() | TransportError.t()
    def stream_error(%Error{} = e), do: e
    def stream_error(%TransportError{} = e), do: e
    def stream_error(reason) when is_atom(reason), do: %TransportError{reason: reason}
    def stream_error(other), do: %TransportError{reason: transport_reason(other)}

    def transaction(conn, _, _) when not is_struct(conn, Conn),
      do: raise(ArgumentError, "expected an Arcadic.Conn as the first argument")

    @impl true
    def transaction(%Conn{} = conn, fun, opts) when is_function(fun, 1) do
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
          Keyword.put(exec_opts(opts), :extra_parameters, run_extra(conn))
        )

      map_transaction_outcome(outcome)
    end

    @doc false
    @spec map_transaction_outcome(term()) ::
            {:ok, term()} | {:error, term()} | {:__rollback__, term()}
    def map_transaction_outcome({:ok, result}), do: {:ok, result}
    def map_transaction_outcome({:error, {:arcadic_rollback, reason}}),
      do: {:__rollback__, reason}

    def map_transaction_outcome({:error, %Error{} = e}), do: {:error, e}
    def map_transaction_outcome({:error, %TransportError{} = e}), do: {:error, e}

    def map_transaction_outcome({:error, :rollback}),
      do: {:error, %Error{reason: :transaction_error, message: "bolt transaction commit failed"}}

    def map_transaction_outcome({:error, _other}),
      do: {:error, %TransportError{reason: :transaction_error}}

    def ready?(conn) when not is_struct(conn, Conn),
      do: raise(ArgumentError, "expected an Arcadic.Conn as the first argument")

    @impl true
    def ready?(%Conn{} = conn) do
      query = %Query{statement: "RETURN 1 AS n"}
      case DBConnection.prepare_execute(bolt(conn), query, %{}, []) do
        {:ok, _, %Response{}} -> {:ok, true}
        {:error, other} -> {:error, %TransportError{reason: transport_reason(other)}}
      end
    end

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

    @doc false
    @spec exec_opts(keyword()) :: keyword()
    def exec_opts(opts), do: Keyword.take(opts, [:timeout])

    @doc false
    @spec transport_reason(term()) :: atom()
    def transport_reason(%TransportError{reason: reason}), do: reason
    def transport_reason(%Error{reason: reason}), do: reason
    def transport_reason(%{__struct__: mod}), do: mod
  end
end
