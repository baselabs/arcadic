defmodule Arcadic.QueryStreamTest do
  use ExUnit.Case, async: true
  alias Arcadic.{Conn, Transport.Bolt}
  alias Boltx.Types.{Duration, Point}

  defmodule CaptureTransport do
    # Not a full @behaviour impl — the facade guards on function_exported?/3, which
    # only needs this one function present. Captures the request the facade builds.
    def query_stream(_conn, request, _opts) do
      send(self(), {:captured_request, request})
      {:ok, []}
    end
  end

  defp bolt_conn(db \\ "mydb"),
    do:
      Conn.new("http://h:2480", db,
        auth: {"u", "p"},
        transport: Bolt,
        transport_options: [bolt: :ignored]
      )

  describe "Bolt.run_extra/1 and format_params/1" do
    test "run_extra/1 carries the conn database as the db extra" do
      assert Bolt.run_extra(bolt_conn("mydb")) == %{db: "mydb"}
    end

    test "format_params/1 is identity for scalar/map/list params" do
      params = %{"k" => "v", "n" => 5, "l" => [1, 2], "m" => %{"a" => 1}}
      assert Bolt.format_params(params) == params
    end

    test "format_params/1 handles the empty map" do
      assert Bolt.format_params(%{}) == %{}
    end

    test "format_params/1 formats Duration/Point params via boltx (not passthrough)" do
      dur = %Duration{days: 1, hours: 2, minutes: 3, seconds: 4}
      point = Point.create(:cartesian, 10, 20.0)

      {:ok, expected_dur} = Duration.format_param(dur)
      {:ok, expected_point} = Point.format_param(point)

      # The formatted value must differ from the raw struct, else this asserts nothing.
      refute expected_dur == dur
      refute expected_point == point

      assert Bolt.format_params(%{"d" => dur, "p" => point}) == %{
               "d" => expected_dur,
               "p" => expected_point
             }
    end
  end

  describe "Bolt.resolve_opts/1" do
    test "applies the ArcadeDB v4 defaults and nests auth" do
      r = Bolt.resolve_opts(hostname: "h", port: 7687, username: "root", password: "pw")
      assert r[:scheme] == "bolt"
      assert r[:versions] == [4.4, 4.3, 4.2, 4.1]
      assert r[:auth] == [username: "root", password: "pw"]
      assert r[:hostname] == "h"
      refute Keyword.has_key?(r, :username)
      refute Keyword.has_key?(r, :password)
    end
  end

  describe "Bolt.map_transaction_outcome/1 (F6)" do
    test "passes through ok and intentional rollback reasons" do
      assert Bolt.map_transaction_outcome({:ok, 42}) == {:ok, 42}
      assert Bolt.map_transaction_outcome({:error, {:arcadic_rollback, :nope}}) == {:error, :nope}
    end

    test "maps DBConnection's bare :rollback commit-failure to a typed error" do
      assert {:error, %Arcadic.Error{reason: :transaction_error}} =
               Bolt.map_transaction_outcome({:error, :rollback})
    end

    test "maps a Boltx.Error via the reason taxonomy" do
      e = %Boltx.Error{
        code: :syntax_error,
        bolt: %{code: "Neo.ClientError.Statement.SyntaxError"}
      }

      assert {:error, %Arcadic.Error{reason: :parse_error}} =
               Bolt.map_transaction_outcome({:error, e})
    end

    test "maps any other unexpected term to a typed, value-free transport error (no bare passthrough)" do
      assert {:error, %Arcadic.TransportError{reason: :transaction_error}} =
               Bolt.map_transaction_outcome({:error, :something_unexpected})
    end
  end

  describe "Bolt.assert_has_more_key!/2 (drift guard)" do
    test "raises a bolt_protocol_error when the first chunk's success map lacks has_more" do
      err = assert_raise Arcadic.TransportError, fn -> Bolt.assert_has_more_key!(%{}, true) end
      assert err.reason == :bolt_protocol_error
      # non-first chunk and present-key are permissive (present-key on first chunk
      # returns nil — the `unless` guard's value when its condition is false):
      assert Bolt.assert_has_more_key!(%{}, false) == :ok
      assert Bolt.assert_has_more_key!(%{"has_more" => true}, true) == nil
    end
  end

  describe "Bolt.stream_error/1 (mid-stream error mapping + redaction)" do
    test "maps a Boltx timeout to a typed transport :timeout error" do
      assert Bolt.stream_error(%Boltx.Error{code: :timeout}) ==
               %Arcadic.TransportError{reason: :timeout}
    end

    test "maps a bare socket atom (e.g. :closed) to a typed transport error" do
      assert Bolt.stream_error(:closed) == %Arcadic.TransportError{reason: :closed}
    end

    test "a value-bearing server error redacts: sentinel in neither message/1 nor inspect" do
      sentinel = "row-value-and-email@example.com-SEKRET"

      e = %Boltx.Error{
        code: :syntax_error,
        bolt: %{code: "Neo.ClientError.Statement.SyntaxError", message: sentinel}
      }

      err = Bolt.stream_error(e)
      assert %Arcadic.Error{reason: :parse_error} = err
      # The value-bearing bolt.message must not survive into the raised exception.
      refute Exception.message(err) =~ sentinel
      refute inspect(err) =~ sentinel
    end
  end

  describe "Bolt.query_stream/3 guards (server-free)" do
    # replaces the old blanket in-tx refusal — an in-tx Bolt conn with no tx_ref is a
    # malformed conn, raised value-free (in-tx streaming policy now lives in the transport).
    test "in a tx conn missing the :bolt tx_ref raises value-free" do
      conn = %{bolt_conn() | session_id: "bolt", transport_options: [bolt_opts: []]}

      assert_raise ArgumentError, ~r/transaction conn/, fn ->
        Bolt.query_stream(
          conn,
          %{statement: "MATCH (n) RETURN n", params: %{}, language: "cypher"},
          []
        )
      end
    end

    test "refuses when transport_options[:bolt_opts] is absent" do
      conn =
        Conn.new("http://h:2480", "db",
          auth: {"u", "p"},
          transport: Bolt,
          transport_options: [bolt: :p]
        )

      assert {:error,
              %Arcadic.Error{
                reason: :not_supported,
                message: "bolt streaming requires transport_options[:bolt_opts]"
              }} =
               Bolt.query_stream(
                 conn,
                 %{statement: "RETURN 1", params: %{}, language: "cypher"},
                 []
               )
    end
  end

  describe "Arcadic.query_stream/4 facade guards" do
    test "the default HTTP transport streams, but requires language: sql" do
      conn = Conn.new("http://localhost:2480", "db", auth: {"u", "p"})

      assert {:error, %Arcadic.Error{reason: :not_supported, message: msg}} =
               Arcadic.query_stream(conn, "MATCH (n) RETURN n")

      assert msg =~ "requires language"
    end

    test "rejects unknown options" do
      conn = Conn.new("http://localhost:2480", "db", auth: {"u", "p"})
      assert_raise ArgumentError, fn -> Arcadic.query_stream(conn, "RETURN 1", %{}, bogus: 1) end
    end

    test "rejects non-keyword opts value-free — never echoes the offending entry (Rule 3)" do
      conn = Conn.new("http://localhost:2480", "db", auth: {"u", "p"})

      err =
        assert_raise ArgumentError, fn ->
          Arcadic.query_stream(conn, "RETURN 1", %{}, [:SENTINEL_SECRET_9f3a])
        end

      assert err.message == "opts must be a keyword list"
      refute err.message =~ "SENTINEL"
    end

    test "passes the value as a bound param, never interpolated into the statement" do
      conn =
        Conn.new("http://h:2480", "db",
          auth: {"u", "p"},
          transport: CaptureTransport,
          transport_options: []
        )

      stmt = "MATCH (n:User {email:$e}) RETURN n"
      assert {:ok, []} = Arcadic.query_stream(conn, stmt, %{"e" => "secret@example.com"})

      assert_received {:captured_request,
                       %{statement: ^stmt, params: %{"e" => "secret@example.com"}}}

      refute stmt =~ "secret@example.com"
    end
  end

  describe "HTTP query_stream/3 (offset paging)" do
    defp http_conn,
      do:
        Conn.new("http://arcade.invalid", "mydb",
          auth: {"root", "x"},
          transport_options: [plug: {Req.Test, __MODULE__}]
        )

    # Stub N sequential pages; capture each page's request body.
    defp stub_pages(pages) do
      {:ok, agent} = Agent.start_link(fn -> pages end)

      Req.Test.stub(__MODULE__, fn c ->
        send(self(), {:page_body, Jason.decode!(Req.Test.raw_body(c))})
        rows = Agent.get_and_update(agent, fn [h | t] -> {h, t} end)
        Req.Test.json(c, %{"result" => rows})
      end)
    end

    test "pages via ORDER BY @rid SKIP/LIMIT (offsets param-bound) and drains on a short page" do
      # chunk 2: page1 [2 rows] → page2 [1 row, short → last]
      stub_pages([
        [%{"@rid" => "#1:0", "n" => 1}, %{"@rid" => "#1:1", "n" => 2}],
        [%{"@rid" => "#1:2", "n" => 3}]
      ])

      assert {:ok, stream} =
               Arcadic.query_stream(http_conn(), "SELECT FROM V", %{},
                 language: "sql",
                 chunk_size: 2
               )

      assert Enum.map(Enum.to_list(stream), & &1["n"]) == [1, 2, 3]

      assert_received {:page_body, b1}

      assert b1["command"] ==
               "SELECT FROM V ORDER BY @rid SKIP $__arcadic_skip LIMIT $__arcadic_limit"

      assert b1["language"] == "sql"
      assert b1["params"] == %{"__arcadic_skip" => 0, "__arcadic_limit" => 2}
      assert_received {:page_body, b2}
      assert b2["params"] == %{"__arcadic_skip" => 2, "__arcadic_limit" => 2}
      # exactly 2 pages (drained on the short page — no third POST)
      refute_received {:page_body, _}
    end

    test "strips the ORDER BY alias leak and @props from streamed rows" do
      stub_pages([
        [%{"n" => 1, "_$$$ORDER_BY_ALIAS$$$_0" => "#1:0", "@props" => "x:1"}]
      ])

      assert {:ok, stream} =
               Arcadic.query_stream(http_conn(), "SELECT n FROM V", %{},
                 language: "sql",
                 chunk_size: 2
               )

      assert [row] = Enum.to_list(stream)
      assert row == %{"n" => 1}
    end

    test "refuses a non-sql language value-free without touching the wire" do
      Req.Test.stub(__MODULE__, fn _ -> flunk("must not reach the transport") end)

      assert {:error, %Arcadic.Error{reason: :not_supported} = e} =
               Arcadic.query_stream(http_conn(), "SELECT FROM V", %{}, language: "cypher")

      assert e.message =~ "requires language"
      refute_received {:page_body, _}
    end

    test "refuses a statement carrying its own ORDER BY/SKIP/LIMIT value-free, no wire, no echo" do
      Req.Test.stub(__MODULE__, fn _ -> flunk("must not reach the transport") end)
      secret = "SECRET_col_9f3a"

      assert {:error, %Arcadic.Error{reason: :not_supported} = e} =
               Arcadic.query_stream(http_conn(), "SELECT FROM V ORDER BY #{secret}", %{},
                 language: "sql"
               )

      refute e.message =~ secret

      assert {:error, %Arcadic.Error{reason: :not_supported}} =
               Arcadic.query_stream(http_conn(), "SELECT FROM V LIMIT 5", %{}, language: "sql")

      refute_received {:page_body, _}
    end

    test "refuses HTTP streaming inside a transaction value-free" do
      Req.Test.stub(__MODULE__, fn _ -> flunk("must not reach the transport") end)
      conn = %{http_conn() | session_id: "sess-1"}

      assert {:error, %Arcadic.Error{reason: :not_supported} = e} =
               Arcadic.query_stream(conn, "SELECT FROM V", %{}, language: "sql")

      assert e.message =~ "inside a transaction"
      refute_received {:page_body, _}
    end

    test "a mid-stream error page RAISES a typed error and redacts the server value" do
      secret = "row-value-and-email@example.com-SEKRET"

      Req.Test.stub(__MODULE__, fn c ->
        c
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{
          "exception" => "com.arcadedb.exception.ParsingException",
          "error" => secret,
          "detail" => secret
        })
      end)

      assert {:ok, stream} =
               Arcadic.query_stream(http_conn(), "SELECT FROM V", %{}, language: "sql")

      err = assert_raise Arcadic.Error, fn -> Enum.to_list(stream) end
      assert err.reason == :parse_error
      # The value-bearing server `error`/`detail` must not survive into the raised exception.
      refute Exception.message(err) =~ secret
      refute inspect(err) =~ secret
    end
  end
end
