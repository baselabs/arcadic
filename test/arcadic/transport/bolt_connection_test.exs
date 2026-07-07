if Code.ensure_loaded?(Boltx) do
  defmodule Arcadic.Transport.Bolt.ConnectionTest do
    use ExUnit.Case, async: true
    alias Arcadic.Transport.Bolt.Connection
    alias Arcadic.TransportError

    # A minimal state carrying the cursor flag; the guard reads only :cursor_open?, so a
    # bare map exercises it server-free (mirrors bolt.ex assert_has_more_key!/2 unit style).
    test "handle_execute refuses value-free while a cursor is open (no interleave on the tx socket)" do
      state = %{client: :fake, cursor_open?: true}

      assert {:error, %TransportError{reason: :cursor_open}, ^state} =
               Connection.handle_execute(:q, %{}, [], state)
    end

    test "handle_declare refuses a second concurrent cursor value-free" do
      state = %{client: :fake, cursor_open?: true}

      assert {:error, %TransportError{reason: :cursor_already_open}, ^state} =
               Connection.handle_declare(:q, %{}, [], state)
    end

    # A %Boltx.Client{} whose TCP socket is already closed, so Client.send_packet/recv_packets
    # return {:error, :closed} — the cheapest server-free way to drive the cursor callbacks'
    # wire-fault path. A wire fault desyncs the shared tx socket, so the callbacks must
    # {:disconnect, …} (drop the poisoned conn), NOT {:error, …} (which DBConnection keeps checked in).
    defp dead_client do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false])
      {:ok, port} = :inet.port(listener)
      {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
      :gen_tcp.close(sock)
      :gen_tcp.close(listener)
      %Boltx.Client{sock: {:gen_tcp, sock}, bolt_version: 4.4}
    end

    test "handle_declare DISCONNECTS on a wire fault (drops the poisoned conn, not {:error})" do
      state = %{client: dead_client(), cursor_open?: false}

      assert {:disconnect, %TransportError{}, _state} =
               Connection.handle_declare("RETURN 1", %{}, [], state)
    end

    test "handle_fetch DISCONNECTS on a wire fault AND clears cursor_open? (so cleanup won't DISCARD a broken socket)" do
      state = %{client: dead_client(), first_chunk?: true, cursor_open?: true}

      assert {:disconnect, %TransportError{}, %{cursor_open?: false}} =
               Connection.handle_fetch(:q, %{run: :r}, [], state)
    end

    test "handle_deallocate DISCONNECTS when the DISCARD-drain itself fails (never returns the conn dirty as {:ok})" do
      state = %{client: dead_client(), cursor_open?: true}

      assert {:disconnect, %TransportError{}, %{cursor_open?: false}} =
               Connection.handle_deallocate(:q, :cursor, [], state)
    end

    test "stream_run/stream_pull are public @doc false frame helpers (the single RUN/PULL site)" do
      # The dedup promotes these to public so connection.ex consumes ONE framing site. Their
      # existence + arity is the contract; behavior is covered by the wire-fault + integration tests.
      # Force the load first: this module aliases only Bolt.Connection, so in an isolated run
      # `Arcadic.Transport.Bolt` is otherwise never loaded and function_exported?/3 is vacuously false.
      assert Code.ensure_loaded?(Arcadic.Transport.Bolt)
      assert function_exported?(Arcadic.Transport.Bolt, :stream_run, 5)
      assert function_exported?(Arcadic.Transport.Bolt, :stream_pull, 3)
    end

    test "connection.ex consumes the shared RUN/PULL framing — no re-inlined encoding (dedup invariant)" do
      # The S6 dedup's contract is ONE framing site: the cursor callbacks must route through
      # Bolt.stream_run/stream_pull, never re-encode RUN/PULL themselves. function_exported?/3
      # above proves the helpers are PUBLIC; this guards the other half — that connection.ex
      # actually CONSUMES them — so a future re-inline of RunMessage/PullMessage.encode (recreating
      # the second framing site the dedup removed) fails RED. Structural, because the SUCCESS-path
      # wire behavior needs a live server (covered by the integration suite); the wire-fault unit
      # tests cover the fault path.
      src = File.read!("lib/arcadic/transport/bolt/connection.ex")

      refute src =~ "RunMessage.encode",
             "handle_declare must consume Bolt.stream_run, not re-inline RUN framing"

      refute src =~ "PullMessage.encode",
             "handle_fetch must consume Bolt.stream_pull, not re-inline PULL framing"

      assert src =~ "Bolt.stream_run"
      assert src =~ "Bolt.stream_pull"
    end
  end

  defmodule Arcadic.Transport.Bolt.ResolveOptsTest do
    use ExUnit.Case, async: true
    alias Arcadic.Transport.Bolt

    test "defaults to plaintext bolt (never boltx's own bolt+s/verify_none default)" do
      opts = Bolt.resolve_opts(hostname: "h", username: "u", password: "p")
      assert opts[:scheme] == "bolt"
      refute Keyword.has_key?(opts, :ssl_opts)
    end

    test "arcadic bolt+s is SECURE → boltx bolt+ssc (which FORCES verify_peer) + OS cacerts" do
      opts = Bolt.resolve_opts(scheme: "bolt+s", hostname: "h", username: "u", password: "p")
      # boltx maps bolt+ssc → verify_peer and bolt+s → verify_none; bolt+ssc is the EFFECTIVE
      # secure scheme (asserting ssl_opts[:verify] here would be vacuous — boltx re-derives it).
      assert opts[:scheme] == "bolt+ssc"
      assert is_list(opts[:ssl_opts][:cacerts])
    end

    test "a caller CA source (cacertfile) is preserved on the secure path" do
      opts =
        Bolt.resolve_opts(
          scheme: "bolt+s",
          ssl_opts: [cacertfile: "/ca.pem"],
          hostname: "h",
          username: "u",
          password: "p"
        )

      assert opts[:scheme] == "bolt+ssc"
      assert opts[:ssl_opts][:cacertfile] == "/ca.pem"
      refute Keyword.has_key?(opts[:ssl_opts], :cacerts)
    end

    test "a caller-pinned cacerts is preserved (not diluted by the OS trust store)" do
      der = "fake-der-bytes"

      opts =
        Bolt.resolve_opts(
          scheme: "bolt+s",
          ssl_opts: [cacerts: [der]],
          hostname: "h",
          username: "u",
          password: "p"
        )

      assert opts[:scheme] == "bolt+ssc"
      assert opts[:ssl_opts][:cacerts] == [der]
      refute Keyword.has_key?(opts[:ssl_opts], :cacertfile)
    end

    test "explicit verify_none opts INTO the insecure boltx bolt+s scheme" do
      opts =
        Bolt.resolve_opts(
          scheme: "bolt+s",
          ssl_opts: [verify: :verify_none],
          hostname: "h",
          username: "u",
          password: "p"
        )

      assert opts[:scheme] == "bolt+s"
      assert opts[:ssl_opts] == [verify: :verify_none]
    end

    test "rejects an unknown scheme value-free" do
      assert_raise ArgumentError, ~r/scheme/, fn ->
        Bolt.resolve_opts(scheme: "http", hostname: "h", username: "u", password: "p")
      end
    end

    test "rejects a :uri opt — it bypasses arcadic's TLS scheme translation (boltx prefers the uri scheme, silently verify_none)" do
      # boltx's Client.Config prefers parsed_uri.scheme over the :scheme opt, and boltx maps its
      # own "bolt+s" to verify_none — so a "bolt+s://" :uri would sail past @schemes + the
      # secure-default translation and open TLS unauthenticated. arcadic must OWN the scheme.
      assert_raise ArgumentError, ~r/uri/, fn ->
        Bolt.resolve_opts(uri: "bolt+s://h:7687", username: "u", password: "p")
      end
    end
  end

  defmodule Arcadic.Transport.Bolt.ResolveOptsEnvTest do
    # async: false — these tests mutate GLOBAL OS env; they must not run concurrently with any
    # test that reads env. Each restores by DELETE (the vars are unset by default, so put_env(nil)
    # is wrong — it would leave a poisoned "" and boltx reads presence, not value).
    use ExUnit.Case, async: false
    alias Arcadic.Transport.Bolt

    for var <- ~w(BOLT_USER BOLT_PWD BOLT_HOST BOLT_TCP_PORT) do
      test "resolve_opts fails loud (value-free, names the var) when #{var} is set" do
        var = unquote(var)
        System.put_env(var, "operator-set-value")
        on_exit(fn -> System.delete_env(var) end)

        err =
          assert_raise ArgumentError, fn ->
            Bolt.resolve_opts(hostname: "h", port: 7687, username: "u", password: "p")
          end

        # names the offending VAR (a fixed identifier), never its value (Rule 3).
        assert err.message =~ var
        refute err.message =~ "operator-set-value"
      end
    end

    test "resolve_opts succeeds normally when no BOLT_* env var is set" do
      for v <- ~w(BOLT_USER BOLT_PWD BOLT_HOST BOLT_TCP_PORT), do: System.delete_env(v)
      opts = Bolt.resolve_opts(hostname: "h", port: 7687, username: "u", password: "p")
      assert opts[:scheme] == "bolt"
      assert opts[:auth] == [username: "u", password: "p"]
    end
  end

  defmodule Arcadic.Transport.Bolt.ConnectEnvRejectTest do
    # The CONNECT-time half of the BOLT_* guard. boltx re-reads BOLT_* at Client.Config.new/1,
    # which leak_safe_connect/1 calls on EVERY pool connect/reconnect (Connection.connect) AND
    # every dedicated stream connect — so a var set AFTER resolve_opts already ran would otherwise
    # silently hijack credentials/port at connect time (resolve_opts guards only resolution time).
    # leak_safe_connect must re-reject at the connect chokepoint. async: false — mutates global OS
    # env; restore by DELETE (unset by default, so put_env(nil) would poison with "").
    use ExUnit.Case, async: false
    alias Arcadic.Transport.Bolt

    for var <- ~w(BOLT_USER BOLT_PWD BOLT_HOST BOLT_TCP_PORT) do
      test "leak_safe_connect fails loud (value-free, names the var) when #{var} is set post-resolution" do
        var = unquote(var)
        # Resolve with env UNSET (resolve_opts' guard passes), THEN set the var — the exact
        # post-resolution window boltx's Config.new would honor. The connect-time reject must fire
        # BEFORE any socket work, so no live server is needed (a bad host would otherwise {:error}).
        for v <- ~w(BOLT_USER BOLT_PWD BOLT_HOST BOLT_TCP_PORT), do: System.delete_env(v)
        opts = Bolt.resolve_opts(hostname: "127.0.0.1", port: 1, username: "u", password: "p")
        System.put_env(var, "operator-set-value")
        on_exit(fn -> System.delete_env(var) end)

        err = assert_raise ArgumentError, fn -> Bolt.leak_safe_connect(opts) end

        assert err.message =~ var
        refute err.message =~ "operator-set-value"
      end
    end
  end
end
