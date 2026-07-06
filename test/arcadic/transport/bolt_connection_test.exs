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
end
