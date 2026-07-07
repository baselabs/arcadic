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

  defmodule NoStreamTransport do
    # Deliberately exports NO query_stream/3 — the facade's function_exported?/3 guard must
    # fall to the "transport does not support streaming" branch (a third-party transport case;
    # both in-tree transports export it, so nothing else exercises that branch).
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
    test "the default HTTP transport streams Cypher but requires :order_key" do
      conn = Conn.new("http://localhost:2480", "db", auth: {"u", "p"})

      # default language is cypher; without :order_key it is rejected naming the requirement.
      assert {:error, %Arcadic.Error{reason: :not_supported, message: msg}} =
               Arcadic.query_stream(conn, "MATCH (n) RETURN n")

      assert msg =~ "order_key"
    end

    test "rejects unknown options" do
      conn = Conn.new("http://localhost:2480", "db", auth: {"u", "p"})
      assert_raise ArgumentError, fn -> Arcadic.query_stream(conn, "RETURN 1", %{}, bogus: 1) end
    end

    test "returns :not_supported when the transport does not export query_stream/3" do
      conn =
        Conn.new("http://h:2480", "db",
          auth: {"u", "p"},
          transport: NoStreamTransport,
          transport_options: []
        )

      assert {:error,
              %Arcadic.Error{
                reason: :not_supported,
                message: "transport does not support streaming"
              }} = Arcadic.query_stream(conn, "RETURN 1", %{}, language: "cypher")
    end

    test "rejects a non-positive chunk_size at the facade (value-free, before routing)" do
      conn = Conn.new("http://localhost:2480", "db", auth: {"u", "p"})

      err =
        assert_raise ArgumentError, fn ->
          Arcadic.query_stream(conn, "RETURN 1", %{}, chunk_size: 0)
        end

      assert err.message =~ "chunk_size"
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

    test "rejects non-map params value-free — never echoes the offending value (Rule 3)" do
      conn = Conn.new("http://localhost:2480", "db", auth: {"u", "p"})

      # A caller passing a keyword list for params (a natural mistake — opts IS a keyword list) must
      # NOT reach `Map.has_key?`/`map_size` and blow up with a BadMapError echoing the value.
      err =
        assert_raise ArgumentError, fn ->
          Arcadic.query_stream(conn, "SELECT FROM V", [{"api_token", "SENTINEL_SECRET_9f3a"}],
            language: "sql"
          )
        end

      assert err.message =~ "params"
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

    test "SQL WHERE-less pages by @rid KEYSET (literal cursor), not offset, and drains on a short page" do
      # chunk 2: page1 [2 rows @rid #1:0,#1:1] → page2 [1 row #1:2, short → last]
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

      # page 1: NO WHERE, just ORDER BY @rid LIMIT (param-bound); no SKIP.
      assert_received {:page_body, b1}
      assert b1["command"] == "SELECT FROM V ORDER BY @rid LIMIT :__arcadic_limit"
      assert b1["params"] == %{"__arcadic_limit" => 2}
      refute Map.has_key?(b1["params"], "__arcadic_skip")
      assert b1["limit"] == 2

      # page 2: WHERE @rid > <literal cursor from page-1's MAX @rid #1:1>, still ORDER BY @rid LIMIT.
      assert_received {:page_body, b2}

      assert b2["command"] ==
               "SELECT FROM V WHERE @rid > #1:1 ORDER BY @rid LIMIT :__arcadic_limit"

      assert b2["params"] == %{"__arcadic_limit" => 2}
      # drained on the short page — no third POST
      refute_received {:page_body, _}
    end

    test "SQL keyset reads the cursor from the ORDER BY alias column on a projection (and strips it)" do
      # A projection (SELECT n ...) yields the @rid in _$$$ORDER_BY_ALIAS$$$_0, not an @rid key.
      # With chunk_size 1, a 1-row page EQUALS the chunk (not short), so the stream keeps paging — a
      # trailing EMPTY page is required to drain it (a 1-row page never trips `length < chunk`).
      stub_pages([
        [%{"n" => 1, "_$$$ORDER_BY_ALIAS$$$_0" => "#3:0"}],
        [%{"n" => 2, "_$$$ORDER_BY_ALIAS$$$_0" => "#3:1"}],
        []
      ])

      assert {:ok, stream} =
               Arcadic.query_stream(http_conn(), "SELECT n FROM V", %{},
                 language: "sql",
                 chunk_size: 1
               )

      # pages 1 and 2 each equal chunk (1 row), page 3 is empty → drains; the alias is stripped.
      assert Enum.to_list(stream) == [%{"n" => 1}, %{"n" => 2}]
      assert_received {:page_body, b1}
      assert b1["command"] == "SELECT n FROM V ORDER BY @rid LIMIT :__arcadic_limit"
      assert_received {:page_body, b2}
      # cursor came from the alias column of page-1's last row (#3:0)
      assert b2["command"] ==
               "SELECT n FROM V WHERE @rid > #3:0 ORDER BY @rid LIMIT :__arcadic_limit"
    end

    test "SQL WHERE-present falls back to OFFSET paging (arcadic cannot inject a keyset predicate)" do
      stub_pages([
        [%{"@rid" => "#1:0", "n" => 5}],
        []
      ])

      assert {:ok, stream} =
               Arcadic.query_stream(http_conn(), "SELECT FROM V WHERE n > 4", %{},
                 language: "sql",
                 chunk_size: 1
               )

      assert Enum.map(Enum.to_list(stream), & &1["n"]) == [5]
      assert_received {:page_body, b1}

      # offset suffix (SKIP + LIMIT), NOT a keyset WHERE @rid > … (the statement already has a WHERE).
      assert b1["command"] ==
               "SELECT FROM V WHERE n > 4 ORDER BY @rid SKIP :__arcadic_skip LIMIT :__arcadic_limit"

      assert b1["params"] == %{"__arcadic_skip" => 0, "__arcadic_limit" => 1}
    end

    test "SQL WHERE-sniff is case-insensitive and word-bounded (a 'where' substring in a name is not a WHERE)" do
      stub_pages([[]])
      # 'somewhere' contains 'where' but not as a WHERE clause → still keyset.
      assert {:ok, stream} =
               Arcadic.query_stream(http_conn(), "SELECT somewhere FROM V", %{},
                 language: "sql",
                 chunk_size: 2
               )

      assert Enum.to_list(stream) == []
      assert_received {:page_body, b1}
      assert b1["command"] == "SELECT somewhere FROM V ORDER BY @rid LIMIT :__arcadic_limit"
    end

    test "SQL keyset raises a value-free error if a page row carries no parseable @rid cursor" do
      # A row with neither @rid nor the alias column (protocol drift) must fail LOUD, never
      # silently switch to offset (which could skip/dup rows). No caller value is echoed.
      stub_pages([[%{"n" => 1}]])

      assert {:ok, stream} =
               Arcadic.query_stream(http_conn(), "SELECT FROM V", %{},
                 language: "sql",
                 chunk_size: 1
               )

      err = assert_raise Arcadic.Error, fn -> Enum.to_list(stream) end
      assert err.message =~ "keyset"
      refute err.message =~ "SELECT FROM V"
    end

    test "SQL streaming rejects a statement that REBINDS @rid via a projection alias (silent-truncation guard), value-free" do
      # A caller projection aliasing anything AS `@rid` shadows the real record RID that arcadic's
      # appended `ORDER BY @rid` + keyset cursor depend on: ArcadeDB's ORDER BY @rid binds to the
      # caller alias, the real RID never reaches the row, and the cursor becomes caller-controlled →
      # SILENT truncation or a re-serve loop (live-proven: `SELECT i, '#9:9' AS `@rid`` drops rows).
      # @rid is arcadic's reserved paging column; reject the rebind value-free, like ORDER BY/comment.
      Req.Test.stub(__MODULE__, fn _ -> flunk("must not reach the transport") end)
      secret = "SECRET_9f3a"

      for stmt <- [
            "SELECT i, '#{secret}' AS `@rid` FROM V",
            "SELECT i, x AS @rid FROM V",
            "SELECT i, 'x' `@rid` FROM V"
          ] do
        assert {:error, %Arcadic.Error{reason: :not_supported} = e} =
                 Arcadic.query_stream(http_conn(), stmt, %{}, language: "sql")

        assert e.message =~ "@rid"
        # value-free: the caller statement/value is never echoed (Rule 3)
        refute e.message =~ secret
      end

      refute_received {:page_body, _}
    end

    test "SQL streaming ALLOWS a legitimate bare @rid projection (SELECT @rid, ... is not a rebind)" do
      # `SELECT @rid, n FROM V` PROJECTS the real record @rid (bare, no backtick/AS) — arcadic reads
      # it correctly; only an ALIAS *to* @rid is a collision. This must still stream, not over-reject.
      stub_pages([[%{"@rid" => "#1:0", "n" => 1}]])

      assert {:ok, stream} =
               Arcadic.query_stream(http_conn(), "SELECT @rid, n FROM V", %{},
                 language: "sql",
                 chunk_size: 2
               )

      assert Enum.to_list(stream) == [%{"@rid" => "#1:0", "n" => 1}]
      assert_received {:page_body, b1}
      assert b1["command"] == "SELECT @rid, n FROM V ORDER BY @rid LIMIT :__arcadic_limit"
    end

    test "Cypher streaming is unaffected by an @rid token (cypher pages by id(v) offset, not @rid)" do
      # The @rid reserve applies to SQL only — Cypher advances by arcadic's own offset counter over
      # id(v), never reads an @rid cursor, so an @rid mention must not trip the SQL-only guard.
      {:ok, agent} = Agent.start_link(fn -> [[]] end)

      Req.Test.stub(__MODULE__, fn c ->
        send(self(), {:page_body, Jason.decode!(Req.Test.raw_body(c))})
        rows = Agent.get_and_update(agent, fn [h | t] -> {h, t ++ [[]]} end)
        Req.Test.json(c, %{"result" => rows})
      end)

      assert {:ok, stream} =
               Arcadic.query_stream(http_conn(), "MATCH (v:V) RETURN v.`@rid`", %{},
                 language: "cypher",
                 order_key: "id(v)",
                 chunk_size: 5
               )

      assert Enum.to_list(stream) == []
    end

    test "SQL WHERE-present offset paging (offsets param-bound) drains on a short page" do
      # chunk 2: page1 [2 rows] → page2 [1 row, short → last]
      stub_pages([
        [%{"@rid" => "#1:0", "n" => 1}, %{"@rid" => "#1:1", "n" => 2}],
        [%{"@rid" => "#1:2", "n" => 3}]
      ])

      assert {:ok, stream} =
               Arcadic.query_stream(http_conn(), "SELECT FROM V WHERE n > 0", %{},
                 language: "sql",
                 chunk_size: 2
               )

      assert Enum.map(Enum.to_list(stream), & &1["n"]) == [1, 2, 3]
      assert_received {:page_body, b1}

      assert b1["command"] ==
               "SELECT FROM V WHERE n > 0 ORDER BY @rid SKIP :__arcadic_skip LIMIT :__arcadic_limit"

      assert b1["language"] == "sql"
      assert b1["params"] == %{"__arcadic_skip" => 0, "__arcadic_limit" => 2}
      assert b1["limit"] == 2
      assert_received {:page_body, b2}
      assert b2["params"] == %{"__arcadic_skip" => 2, "__arcadic_limit" => 2}
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

    test "refuses an unsupported language value-free without touching the wire" do
      Req.Test.stub(__MODULE__, fn _ -> flunk("must not reach the transport") end)

      assert {:error, %Arcadic.Error{reason: :not_supported} = e} =
               Arcadic.query_stream(http_conn(), "SELECT FROM V", %{}, language: "gremlin")

      assert e.message =~ "sql"
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

    test "rejects a non-positive chunk_size value-free without touching the wire" do
      Req.Test.stub(__MODULE__, fn _ -> flunk("must not reach the transport") end)

      for bad <- [0, -1] do
        err =
          assert_raise ArgumentError, fn ->
            Arcadic.query_stream(http_conn(), "SELECT FROM V", %{},
              language: "sql",
              chunk_size: bad
            )
          end

        assert err.message =~ "chunk_size"
        # value-free: the offending value is never echoed (Rule 3 posture, also just hygiene)
        refute err.message =~ to_string(bad)
      end

      refute_received {:page_body, _}
    end

    test "refuses a statement carrying a SQL comment token value-free (a trailing -- neutralizes the paging suffix)" do
      Req.Test.stub(__MODULE__, fn _ -> flunk("must not reach the transport") end)
      secret = "SECRET_tail_9f3a"

      assert {:error, %Arcadic.Error{reason: :not_supported} = e} =
               Arcadic.query_stream(http_conn(), "SELECT FROM V -- #{secret}", %{},
                 language: "sql"
               )

      refute e.message =~ secret

      assert {:error, %Arcadic.Error{reason: :not_supported}} =
               Arcadic.query_stream(http_conn(), "SELECT FROM V /* x */", %{}, language: "sql")

      refute_received {:page_body, _}
    end

    test "refuses a caller param colliding with the reserved paging namespace value-free (string AND atom keys)" do
      Req.Test.stub(__MODULE__, fn _ -> flunk("must not reach the transport") end)

      # Both key forms must be caught: an ATOM key would slip a string-only guard, then Jason
      # stringifies it into a DUPLICATE JSON key that ArcadeDB binds last → the caller's own
      # predicate silently mis-binds to the page offset.
      for key <- ["__arcadic_skip", "__arcadic_limit", :__arcadic_skip, :__arcadic_limit] do
        assert {:error, %Arcadic.Error{reason: :not_supported} = e} =
                 Arcadic.query_stream(http_conn(), "SELECT FROM V", %{key => 7}, language: "sql")

        assert e.message =~ "reserve"
      end

      refute_received {:page_body, _}
    end

    test "emits query_stream :start and :stop telemetry (value-free) around the HTTP stream" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:arcadic, :query_stream, :start],
          [:arcadic, :query_stream, :stop]
        ])

      stub_pages([
        [%{"@rid" => "#1:0", "n" => 1}, %{"@rid" => "#1:1", "n" => 2}],
        [%{"@rid" => "#1:2", "n" => 3}]
      ])

      assert {:ok, stream} =
               Arcadic.query_stream(http_conn(), "SELECT FROM V", %{},
                 language: "sql",
                 chunk_size: 2
               )

      # lazy — no event until enumeration begins (start fires in the Stream.resource start-fun)
      refute_received {[:arcadic, :query_stream, :start], ^ref, _, _}

      assert length(Enum.to_list(stream)) == 3

      assert_received {[:arcadic, :query_stream, :start], ^ref, _measurements, %{mode: :read}}

      assert_received {[:arcadic, :query_stream, :stop], ^ref, %{row_count: 3},
                       %{mode: :read, reason: :ok}}

      :telemetry.detach(ref)
    end

    test "an early-halted HTTP stream stops with reason: :halted" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:arcadic, :query_stream, :stop]])

      stub_pages([
        [%{"@rid" => "#1:0", "n" => 1}, %{"@rid" => "#1:1", "n" => 2}],
        [%{"@rid" => "#1:2", "n" => 3}, %{"@rid" => "#1:3", "n" => 4}]
      ])

      assert {:ok, stream} =
               Arcadic.query_stream(http_conn(), "SELECT FROM V", %{},
                 language: "sql",
                 chunk_size: 2
               )

      assert Enum.take(stream, 1) == [%{"@rid" => "#1:0", "n" => 1}]

      assert_received {[:arcadic, :query_stream, :stop], ^ref, %{row_count: _},
                       %{mode: :read, reason: :halted}}

      :telemetry.detach(ref)
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

    test "Cypher requires :order_key — absent → value-free :not_supported naming the requirement" do
      Req.Test.stub(__MODULE__, fn _ -> flunk("must not reach the transport") end)
      secret = "MATCH (s:SECRET_9f3a) RETURN s"

      assert {:error, %Arcadic.Error{reason: :not_supported} = e} =
               Arcadic.query_stream(http_conn(), secret, %{}, language: "cypher")

      assert e.message =~ "order_key"
      # value-free: the statement is never echoed
      refute e.message =~ "SECRET_9f3a"
      refute_received {:page_body, _}
    end

    test "Cypher order_key allowlist: accepts id(<identifier>), rejects everything else value-free" do
      Req.Test.stub(__MODULE__, fn _ -> flunk("must not reach the transport") end)

      # rejected: non-unique key, second clause, comment smuggle, embedded newline, a function payload,
      # @rid (SQL cursor on cypher), unbalanced/empty, uppercase-ID with a dot.
      for bad <- [
            "n.age",
            "id(n) OR 1=1",
            "id(n)//",
            "id(n)\n",
            "id(n); DROP",
            "count(n)",
            "@rid",
            "id()",
            "id(n).x"
          ] do
        assert {:error, %Arcadic.Error{reason: :not_supported} = e} =
                 Arcadic.query_stream(http_conn(), "MATCH (n:V) RETURN n", %{},
                   language: "cypher",
                   order_key: bad
                 )

        assert e.message =~ "order_key"
        refute e.message =~ bad
      end

      refute_received {:page_body, _}
    end

    test "Cypher order_key accepts id(<identifier>) forms" do
      # accepted shapes drive the paging path (stubbed empty → drains immediately).
      {:ok, agent} = Agent.start_link(fn -> [[]] end)

      Req.Test.stub(__MODULE__, fn c ->
        send(self(), {:page_body, Jason.decode!(Req.Test.raw_body(c))})
        rows = Agent.get_and_update(agent, fn [h | t] -> {h, t ++ [[]]} end)
        Req.Test.json(c, %{"result" => rows})
      end)

      for good <- ["id(n)", "id(v)", "id(_x)", "id(Node1)"] do
        assert {:ok, stream} =
                 Arcadic.query_stream(http_conn(), "MATCH (n:V) RETURN n", %{},
                   language: "cypher",
                   order_key: good,
                   chunk_size: 5
                 )

        assert Enum.to_list(stream) == []
      end
    end

    test "Cypher pages by OFFSET with $name placeholders and the given order_key" do
      {:ok, agent} = Agent.start_link(fn -> [[%{"i" => 1}], []] end)

      Req.Test.stub(__MODULE__, fn c ->
        send(self(), {:page_body, Jason.decode!(Req.Test.raw_body(c))})
        rows = Agent.get_and_update(agent, fn [h | t] -> {h, t} end)
        Req.Test.json(c, %{"result" => rows})
      end)

      assert {:ok, stream} =
               Arcadic.query_stream(http_conn(), "MATCH (v:V) RETURN v", %{},
                 language: "cypher",
                 order_key: "id(v)",
                 chunk_size: 1
               )

      assert Enum.to_list(stream) == [%{"i" => 1}]
      assert_received {:page_body, b1}
      # Cypher $name placeholders (NOT SQL :name) and the caller order_key.
      assert b1["command"] ==
               "MATCH (v:V) RETURN v ORDER BY id(v) SKIP $__arcadic_skip LIMIT $__arcadic_limit"

      assert b1["language"] == "cypher"
      assert b1["params"] == %{"__arcadic_skip" => 0, "__arcadic_limit" => 1}
      assert b1["limit"] == 1
      assert_received {:page_body, b2}
      assert b2["params"] == %{"__arcadic_skip" => 1, "__arcadic_limit" => 1}
    end

    test "Cypher rejects a // line comment (would neutralize the appended paging suffix)" do
      Req.Test.stub(__MODULE__, fn _ -> flunk("must not reach the transport") end)

      assert {:error, %Arcadic.Error{reason: :not_supported} = e} =
               Arcadic.query_stream(http_conn(), "MATCH (v:V) RETURN v //", %{},
                 language: "cypher",
                 order_key: "id(v)"
               )

      assert e.message =~ "comment"
      refute_received {:page_body, _}
    end

    test "SQL still rejects -- and /* but a bare // does NOT block a SQL statement (SQL has no // comment)" do
      # The // token is Cypher-only; a SQL statement containing // (e.g. a path literal) is not
      # comment-guarded by //. Confirm the SQL guard is unchanged (-- / /* still rejected).
      Req.Test.stub(__MODULE__, fn _ -> flunk("must not reach the transport") end)

      assert {:error, %Arcadic.Error{reason: :not_supported}} =
               Arcadic.query_stream(http_conn(), "SELECT FROM V -- x", %{}, language: "sql")

      assert {:error, %Arcadic.Error{reason: :not_supported}} =
               Arcadic.query_stream(http_conn(), "SELECT FROM V /* x */", %{}, language: "sql")

      refute_received {:page_body, _}
    end
  end
end
