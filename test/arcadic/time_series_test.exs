defmodule Arcadic.TimeSeriesTest do
  use ExUnit.Case, async: true
  alias Arcadic.{Conn, Error, TransportError}
  alias Arcadic.Transport.HTTP

  defp conn,
    do:
      Conn.new("http://arcade.invalid", "tsdb",
        auth: {"root", "x"},
        transport_options: [plug: {Req.Test, __MODULE__}]
      )

  describe "HTTP.ts_write/3" do
    test "POSTs raw line protocol to /api/v1/ts/<db>/write with text/plain and returns :ok on 204" do
      Req.Test.stub(__MODULE__, fn c ->
        assert c.method == "POST"
        assert c.request_path == "/api/v1/ts/tsdb/write"
        assert Plug.Conn.get_req_header(c, "content-type") |> hd() =~ "text/plain"
        send(self(), {:body, Req.Test.raw_body(c)})
        Plug.Conn.send_resp(c, 204, "")
      end)

      assert :ok = HTTP.ts_write(conn(), "cpu,host=a v=1.0 1", [])
      assert_received {:body, body}
      assert IO.iodata_to_binary(body) == "cpu,host=a v=1.0 1"
    end

    test "threads :precision as the ?precision query param" do
      Req.Test.stub(__MODULE__, fn c ->
        assert c.query_string == "precision=ms"
        Plug.Conn.send_resp(c, 204, "")
      end)

      assert :ok = HTTP.ts_write(conn(), "cpu v=1.0", precision: "ms")
    end

    test "a non-binary :precision is rejected value-free (defense in depth)" do
      assert_raise ArgumentError, ~r/invalid :precision/, fn ->
        HTTP.ts_write(conn(), "cpu v=1.0", precision: 5)
      end
    end

    test "a non-2xx JSON error body surfaces a typed %Arcadic.Error{}" do
      Req.Test.stub(__MODULE__, fn c ->
        c
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => "Unknown timeseries type(s): cpu"})
      end)

      assert {:error, %Error{http_status: 400}} = HTTP.ts_write(conn(), "cpu v=1.0", [])
    end

    test "a 2xx OTHER than the contract 204 is :unexpected_response (a 200-JSON write ack is off-contract)" do
      Req.Test.stub(__MODULE__, fn c -> Req.Test.json(c, %{"result" => "ok"}) end)

      assert {:error, %Error{reason: :unexpected_response} = err} =
               HTTP.ts_write(conn(), "cpu v=1.0", [])

      assert Exception.message(err) == "off-contract ts write response"
    end

    test "a transport fault surfaces %Arcadic.TransportError{}" do
      Req.Test.stub(__MODULE__, fn c -> Req.Test.transport_error(c, :econnrefused) end)

      assert {:error, %TransportError{reason: :econnrefused}} =
               HTTP.ts_write(conn(), "cpu v=1.0", [])
    end
  end

  describe "HTTP.ts_query/3" do
    test "POSTs the JSON body and atomizes the RAW response shape" do
      Req.Test.stub(__MODULE__, fn c ->
        assert c.request_path == "/api/v1/ts/tsdb/query"
        {:ok, body, _} = Plug.Conn.read_body(c)
        assert Jason.decode!(body) == %{"type" => "cpu", "from" => 1, "to" => 2}

        Req.Test.json(c, %{
          "type" => "cpu",
          "columns" => ["ts", "v"],
          "rows" => [[1, 1.5]],
          "count" => 1
        })
      end)

      assert {:ok, %{columns: ["ts", "v"], rows: [[1, 1.5]], count: 1}} =
               HTTP.ts_query(conn(), %{"type" => "cpu", "from" => 1, "to" => 2}, [])
    end

    test "atomizes the AGGREGATED response shape (buckets incl. inner keys)" do
      Req.Test.stub(__MODULE__, fn c ->
        Req.Test.json(c, %{
          "type" => "cpu",
          "aggregations" => ["v_avg"],
          "buckets" => [%{"timestamp" => 100, "values" => [9.5]}],
          "count" => 1
        })
      end)

      assert {:ok,
              %{aggregations: ["v_avg"], buckets: [%{timestamp: 100, values: [9.5]}], count: 1}} =
               HTTP.ts_query(conn(), %{"type" => "cpu"}, [])
    end

    test "a rows body missing the count key is :unexpected_response (no fabricated defaults)" do
      Req.Test.stub(__MODULE__, fn c ->
        Req.Test.json(c, %{"type" => "cpu", "columns" => ["ts"], "rows" => [[1]]})
      end)

      assert {:error, %Error{reason: :unexpected_response}} =
               HTTP.ts_query(conn(), %{"type" => "cpu"}, [])
    end

    test "a buckets body missing aggregations/count is :unexpected_response (no fabricated defaults)" do
      Req.Test.stub(__MODULE__, fn c ->
        Req.Test.json(c, %{"type" => "cpu", "buckets" => []})
      end)

      assert {:error, %Error{reason: :unexpected_response}} =
               HTTP.ts_query(conn(), %{"type" => "cpu"}, [])
    end

    test "a NON-MAP bucket element fails the whole response closed, value-free (no BadMapError echoing peer data)" do
      Req.Test.stub(__MODULE__, fn c ->
        Req.Test.json(c, %{
          "type" => "cpu",
          "aggregations" => ["v_avg"],
          "buckets" => ["PEER_SENTINEL_ROW"],
          "count" => 1
        })
      end)

      assert {:error, %Error{reason: :unexpected_response} = err} =
               HTTP.ts_query(conn(), %{"type" => "cpu"}, [])

      refute Exception.message(err) =~ "PEER_SENTINEL_ROW"
    end

    test "a bucket whose values is NOT a list fails the whole response closed" do
      Req.Test.stub(__MODULE__, fn c ->
        Req.Test.json(c, %{
          "type" => "cpu",
          "aggregations" => ["v_avg"],
          "buckets" => [%{"timestamp" => 1, "values" => "PEER_SENTINEL"}],
          "count" => 1
        })
      end)

      assert {:error, %Error{reason: :unexpected_response} = err} =
               HTTP.ts_query(conn(), %{"type" => "cpu"}, [])

      refute Exception.message(err) =~ "PEER_SENTINEL"
    end

    test "a 2xx body missing BOTH rows and buckets is :unexpected_response (off-contract, fail closed)" do
      Req.Test.stub(__MODULE__, fn c -> Req.Test.json(c, %{"something" => "else"}) end)

      assert {:error, %Error{reason: :unexpected_response} = err} =
               HTTP.ts_query(conn(), %{"type" => "cpu"}, [])

      # The authored hint surfaces via Exception.message/1 (client-raised reason).
      assert Exception.message(err) == "off-contract ts query body"
    end

    test "a non-2xx JSON error body surfaces a typed %Arcadic.Error{}" do
      Req.Test.stub(__MODULE__, fn c ->
        c |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
      end)

      assert {:error, %Error{http_status: 500}} = HTTP.ts_query(conn(), %{"type" => "cpu"}, [])
    end
  end

  describe "HTTP.ts_latest/3" do
    test "GETs /latest with encoded query params and atomizes the shape" do
      Req.Test.stub(__MODULE__, fn c ->
        assert c.request_path == "/api/v1/ts/tsdb/latest"
        assert URI.decode_query(c.query_string) == %{"type" => "cpu", "tag" => "host:a"}
        Req.Test.json(c, %{"type" => "cpu", "columns" => ["ts", "v"], "latest" => [1, 2.5]})
      end)

      assert {:ok, %{columns: ["ts", "v"], latest: [1, 2.5]}} =
               HTTP.ts_latest(conn(), [{"type", "cpu"}, {"tag", "host:a"}], [])
    end

    test "a non-2xx JSON error body surfaces a typed %Arcadic.Error{}" do
      Req.Test.stub(__MODULE__, fn c ->
        c |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "bad request"})
      end)

      assert {:error, %Error{http_status: 400}} = HTTP.ts_latest(conn(), [{"type", "cpu"}], [])
    end

    test "a 2xx non-map body is :unexpected_response (off-contract, fail closed)" do
      Req.Test.stub(__MODULE__, fn c -> Plug.Conn.send_resp(c, 200, "not json") end)

      assert {:error, %Error{reason: :unexpected_response}} =
               HTTP.ts_latest(conn(), [{"type", "cpu"}], [])
    end

    test "\"latest\": null normalizes to [] (the live server's on-contract empty-type answer)" do
      Req.Test.stub(__MODULE__, fn c ->
        Req.Test.json(c, %{"type" => "cpu", "columns" => ["ts", "v"], "latest" => nil})
      end)

      assert {:ok, %{columns: ["ts", "v"], latest: []}} =
               HTTP.ts_latest(conn(), [{"type", "cpu"}], [])
    end

    test "a 2xx map MISSING the latest key is :unexpected_response (no fabricated default)" do
      Req.Test.stub(__MODULE__, fn c ->
        Req.Test.json(c, %{"type" => "cpu", "columns" => ["ts", "v"]})
      end)

      assert {:error, %Error{reason: :unexpected_response}} =
               HTTP.ts_latest(conn(), [{"type", "cpu"}], [])
    end

    test "a transport fault surfaces %Arcadic.TransportError{}" do
      Req.Test.stub(__MODULE__, fn c -> Req.Test.transport_error(c, :econnrefused) end)

      assert {:error, %TransportError{reason: :econnrefused}} =
               HTTP.ts_latest(conn(), [{"type", "cpu"}], [])
    end
  end

  describe "HTTP.ts_prom_get/4" do
    test ":query maps to prom/api/v1/query and unwraps the success data envelope" do
      Req.Test.stub(__MODULE__, fn c ->
        assert c.request_path == "/api/v1/ts/tsdb/prom/api/v1/query"
        assert URI.decode_query(c.query_string) == %{"query" => "cpu{host=\"a\"}", "time" => "99"}

        Req.Test.json(c, %{
          "status" => "success",
          "data" => %{"resultType" => "vector", "result" => []}
        })
      end)

      assert {:ok, %{"resultType" => "vector", "result" => []}} =
               HTTP.ts_prom_get(
                 conn(),
                 :query,
                 [{"query", "cpu{host=\"a\"}"}, {"time", "99"}],
                 []
               )
    end

    test "{:label_values, label} interpolates the URL-ENCODED label into the path" do
      # A label whose encoding DIFFERS from its raw form, so deleting the encode call goes red
      # ("__name__" encodes to itself — a vacuous tripwire).
      Req.Test.stub(__MODULE__, fn c ->
        assert c.request_path == "/api/v1/ts/tsdb/prom/api/v1/label/a%2Fb+c/values"
        Req.Test.json(c, %{"status" => "success", "data" => ["cpu"]})
      end)

      assert {:ok, ["cpu"]} = HTTP.ts_prom_get(conn(), {:label_values, "a/b c"}, [], [])
    end

    test ":series sends repeated match[] params" do
      Req.Test.stub(__MODULE__, fn c ->
        assert c.request_path == "/api/v1/ts/tsdb/prom/api/v1/series"
        assert c.query_string == "match%5B%5D=cpu&match%5B%5D=mem"
        Req.Test.json(c, %{"status" => "success", "data" => []})
      end)

      assert {:ok, []} =
               HTTP.ts_prom_get(conn(), :series, [{"match[]", "cpu"}, {"match[]", "mem"}], [])
    end

    test "a Prometheus status:error envelope is a typed error, never a success" do
      Req.Test.stub(__MODULE__, fn c ->
        Req.Test.json(c, %{
          "status" => "error",
          "errorType" => "bad_data",
          "error" => "parse error at 3"
        })
      end)

      # The envelope rides HTTP 200 — the floor to 400 must hold (max(status, 400)), and the
      # server's error text is QUARANTINED in :detail (Rule 3), never in message/1.
      assert {:error, %Error{reason: :server_error, http_status: 400} = err} =
               HTTP.ts_prom_get(conn(), :labels, [], [])

      assert err.detail == "parse error at 3"
      refute Exception.message(err) =~ "parse error at 3"
    end

    test "a malformed 2xx body missing the status envelope is :unexpected_response (fail closed)" do
      Req.Test.stub(__MODULE__, fn c -> Req.Test.json(c, %{"data" => []}) end)

      assert {:error, %Error{reason: :unexpected_response}} =
               HTTP.ts_prom_get(conn(), :labels, [], [])
    end

    test "a success envelope MISSING the data key is :unexpected_response (no fabricated %{} default)" do
      Req.Test.stub(__MODULE__, fn c -> Req.Test.json(c, %{"status" => "success"}) end)

      assert {:error, %Error{reason: :unexpected_response}} =
               HTTP.ts_prom_get(conn(), :labels, [], [])
    end

    test "a non-2xx JSON error body surfaces a typed %Arcadic.Error{}" do
      Req.Test.stub(__MODULE__, fn c ->
        c |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => "not found"})
      end)

      assert {:error, %Error{http_status: 404}} = HTTP.ts_prom_get(conn(), :labels, [], [])
    end

    test "an unknown op atom raises value-free (allowlist, fail closed)" do
      assert_raise ArgumentError, ~r/unknown prom op/, fn ->
        HTTP.ts_prom_get(conn(), :nosuch, [], [])
      end
    end
  end

  describe "DDL emission" do
    alias Arcadic.TimeSeries

    defp stub_command(expected) do
      Req.Test.stub(__MODULE__, fn c ->
        {:ok, body, _} = Plug.Conn.read_body(c)
        decoded = Jason.decode!(body)
        assert decoded["language"] == "sql"
        assert decoded["command"] == expected
        Req.Test.json(c, %{"user" => "root", "result" => [%{"operation" => "x"}]})
      end)
    end

    test "create_type/4 minimal — no PRECISION, no TAGS, no options" do
      stub_command("CREATE TIMESERIES TYPE cpu TIMESTAMP ts FIELDS (v DOUBLE)")
      assert :ok = TimeSeries.create_type(conn(), "cpu", "ts", fields: [v: "DOUBLE"])
    end

    test "create_type/4 full — fixed clause order SHARDS -> RETENTION -> COMPACTION_INTERVAL, plural units" do
      stub_command(
        "CREATE TIMESERIES TYPE cpu TIMESTAMP ts PRECISION MILLISECOND " <>
          "TAGS (host STRING, region STRING) FIELDS (usage DOUBLE, n INTEGER) " <>
          "SHARDS 2 RETENTION 90 DAYS COMPACTION_INTERVAL 1 HOURS"
      )

      assert :ok =
               TimeSeries.create_type(conn(), "cpu", "ts",
                 fields: [usage: "DOUBLE", n: "INTEGER"],
                 tags: [host: "STRING", region: "STRING"],
                 precision: :millisecond,
                 shards: 2,
                 retention: {90, :days},
                 compaction_interval: {1, :hours}
               )
    end

    test "create_type/4 rejects a bad column TYPE token value-free (positive allowlist)" do
      err =
        assert_raise ArgumentError, fn ->
          TimeSeries.create_type(conn(), "cpu", "ts", fields: [v: "DOUBLE; DROP DATABASE x"])
        end

      refute Exception.message(err) =~ "DROP"
    end

    test "create_type/4 rejects a bad identifier via {:error, :invalid_identifier}" do
      assert {:error, :invalid_identifier} =
               TimeSeries.create_type(conn(), "bad name", "ts", fields: [v: "DOUBLE"])

      assert {:error, :invalid_identifier} =
               TimeSeries.create_type(conn(), "cpu", "1bad", fields: [v: "DOUBLE"])

      assert {:error, :invalid_identifier} =
               TimeSeries.create_type(conn(), "cpu", "ts", fields: [{"bad col", "DOUBLE"}])
    end

    test "create_type/4 requires a non-empty :fields" do
      assert_raise ArgumentError, ~r/at least one field/, fn ->
        TimeSeries.create_type(conn(), "cpu", "ts", fields: [])
      end

      assert_raise ArgumentError, ~r/at least one field/, fn ->
        TimeSeries.create_type(conn(), "cpu", "ts", [])
      end
    end

    test "create_type/4 rejects bad durations and precisions value-free" do
      assert_raise ArgumentError, ~r/duration/, fn ->
        TimeSeries.create_type(conn(), "cpu", "ts",
          fields: [v: "DOUBLE"],
          retention: {90, :weeks}
        )
      end

      assert_raise ArgumentError, ~r/duration/, fn ->
        TimeSeries.create_type(conn(), "cpu", "ts", fields: [v: "DOUBLE"], retention: {0, :days})
      end

      assert_raise ArgumentError, ~r/precision/, fn ->
        TimeSeries.create_type(conn(), "cpu", "ts", fields: [v: "DOUBLE"], precision: :nanos)
      end

      assert_raise ArgumentError, ~r/shards/, fn ->
        TimeSeries.create_type(conn(), "cpu", "ts", fields: [v: "DOUBLE"], shards: 0)
      end
    end

    test "drop_type/2 emits plain DROP (no IF EXISTS — absent from the 26.7.2 grammar)" do
      stub_command("DROP TIMESERIES TYPE cpu")
      assert :ok = TimeSeries.drop_type(conn(), "cpu")
    end

    test "add_downsampling/3 emits AFTER + GRANULARITY with plural units; both opts required" do
      stub_command(
        "ALTER TIMESERIES TYPE cpu ADD DOWNSAMPLING POLICY AFTER 7 DAYS GRANULARITY 1 HOURS"
      )

      assert :ok =
               TimeSeries.add_downsampling(conn(), "cpu",
                 after: {7, :days},
                 granularity: {1, :hours}
               )

      assert_raise ArgumentError, ~r/after/, fn ->
        TimeSeries.add_downsampling(conn(), "cpu", granularity: {1, :hours})
      end

      assert_raise ArgumentError, ~r/granularity/, fn ->
        TimeSeries.add_downsampling(conn(), "cpu", after: {7, :days})
      end
    end

    test "drop_downsampling/2" do
      stub_command("ALTER TIMESERIES TYPE cpu DROP DOWNSAMPLING POLICY")
      assert :ok = TimeSeries.drop_downsampling(conn(), "cpu")
    end

    test "bang variants raise on a server error and return :ok on success" do
      Req.Test.stub(__MODULE__, fn c ->
        c
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{
          "error" => "boom",
          "exception" => "com.arcadedb.exception.CommandExecutionException",
          "detail" => "Type 'cpu' already exists"
        })
      end)

      assert_raise Arcadic.Error, fn ->
        TimeSeries.create_type!(conn(), "cpu", "ts", fields: [v: "DOUBLE"])
      end

      stub_command("DROP TIMESERIES TYPE cpu")
      assert :ok = TimeSeries.drop_type!(conn(), "cpu")
    end

    test "bang variants turn a bare error atom into a static ArgumentError (value-free)" do
      err =
        assert_raise ArgumentError, fn ->
          TimeSeries.drop_type!(conn(), "bad name")
        end

      assert err.message == "time-series operation failed: :invalid_identifier"
      refute err.message =~ "bad name"
    end
  end

  describe "continuous aggregates" do
    alias Arcadic.TimeSeries

    test "create_aggregate/3 emits CREATE CONTINUOUS AGGREGATE name AS <select> (select verbatim)" do
      stub_command(
        "CREATE CONTINUOUS AGGREGATE hourly AS SELECT ts.timeBucket('1h', ts) AS hour, avg(v) AS av FROM cpu GROUP BY hour"
      )

      assert :ok =
               TimeSeries.create_aggregate(
                 conn(),
                 "hourly",
                 "SELECT ts.timeBucket('1h', ts) AS hour, avg(v) AS av FROM cpu GROUP BY hour"
               )
    end

    test "create_aggregate/3 raises value-free on a non-binary select; :invalid_identifier on a bad name" do
      err =
        assert_raise ArgumentError, fn ->
          TimeSeries.create_aggregate(conn(), "h", %{secret: "x"})
        end

      refute Exception.message(err) =~ "secret"

      assert {:error, :invalid_identifier} =
               TimeSeries.create_aggregate(conn(), "bad name", "SELECT 1")
    end

    test "create_aggregate/3 fallback is TOTAL — a non-Conn first arg raises the same value-free ArgumentError, never FunctionClauseError (whose blame echoes the args)" do
      err =
        assert_raise ArgumentError, fn ->
          TimeSeries.create_aggregate(:not_a_conn, "h", %{secret: "x"})
        end

      refute Exception.message(err) =~ "secret"
    end

    test "refresh_aggregate/2 and drop_aggregate/2" do
      stub_command("REFRESH CONTINUOUS AGGREGATE hourly")
      assert :ok = TimeSeries.refresh_aggregate(conn(), "hourly")

      stub_command("DROP CONTINUOUS AGGREGATE hourly")
      assert :ok = TimeSeries.drop_aggregate(conn(), "hourly")

      assert {:error, :invalid_identifier} = TimeSeries.refresh_aggregate(conn(), "1bad")
      assert {:error, :invalid_identifier} = TimeSeries.drop_aggregate(conn(), "1bad")
    end

    test "bang variants" do
      stub_command("CREATE CONTINUOUS AGGREGATE hourly AS SELECT 1")
      assert :ok = TimeSeries.create_aggregate!(conn(), "hourly", "SELECT 1")

      stub_command("REFRESH CONTINUOUS AGGREGATE hourly")
      assert :ok = TimeSeries.refresh_aggregate!(conn(), "hourly")

      stub_command("DROP CONTINUOUS AGGREGATE hourly")
      assert :ok = TimeSeries.drop_aggregate!(conn(), "hourly")
    end
  end

  describe "write/3 and the line builder" do
    alias Arcadic.TimeSeries

    defp stub_write(expected_body, expected_query \\ "") do
      Req.Test.stub(__MODULE__, fn c ->
        assert c.request_path == "/api/v1/ts/tsdb/write"
        assert c.query_string == expected_query
        send(self(), {:lines, Req.Test.raw_body(c)})
        Plug.Conn.send_resp(c, 204, "")
      end)

      expected_body
    end

    test "builds a full line: sorted tags, typed fields (int i-suffix, float, bool, string), timestamp" do
      expected =
        stub_write(
          "cpu,host=srv1,region=us msg=\"hi\",n=42i,ok=true,usage=12.5 1700000000000000000"
        )

      point = %{
        type: "cpu",
        tags: %{"region" => "us", "host" => "srv1"},
        fields: %{"usage" => 12.5, "n" => 42, "ok" => true, "msg" => "hi"},
        timestamp: 1_700_000_000_000_000_000
      }

      assert :ok = TimeSeries.write(conn(), [point])
      assert_received {:lines, body}
      assert IO.iodata_to_binary(body) == expected
    end

    test "escapes tag values (space/comma/equals/backslash) and string-field quotes/backslashes" do
      expected =
        stub_write("ev,svc=my\\ svc\\,prod\\=x\\\\y msg=\"quote \\\" back \\\\ slash\" 1")

      point = %{
        type: "ev",
        tags: %{"svc" => ~S(my svc,prod=x\y)},
        fields: %{"msg" => ~S(quote " back \ slash)},
        timestamp: 1
      }

      assert :ok = TimeSeries.write(conn(), [point])
      assert_received {:lines, body}
      assert IO.iodata_to_binary(body) == expected
    end

    test "multi-point bodies join with newline; nil timestamp omits it (server now)" do
      expected = stub_write("a v=1i\nb v=2i 5")

      assert :ok =
               TimeSeries.write(conn(), [
                 %{type: "a", fields: %{"v" => 1}},
                 %{type: "b", fields: %{"v" => 2}, timestamp: 5}
               ])

      assert_received {:lines, body}
      assert IO.iodata_to_binary(body) == expected
    end

    test "atom type and atom tag/field names are converted (the @doc contract)" do
      expected = stub_write("cpu,host=a v=1i 7")

      assert :ok =
               TimeSeries.write(conn(), [
                 %{type: :cpu, tags: %{host: "a"}, fields: %{v: 1}, timestamp: 7}
               ])

      assert_received {:lines, body}
      assert IO.iodata_to_binary(body) == expected
    end

    test ":precision is validated client-side (server silently ignores bad values) and converts DateTime" do
      expected = stub_write("a v=1i 1700000000000", "precision=ms")
      dt = DateTime.from_unix!(1_700_000_000_000, :millisecond)

      assert :ok =
               TimeSeries.write(conn(), [%{type: "a", fields: %{"v" => 1}, timestamp: dt}],
                 precision: :ms
               )

      assert_received {:lines, body}
      assert IO.iodata_to_binary(body) == expected

      assert_raise ArgumentError, ~r/precision/, fn ->
        TimeSeries.write(conn(), [%{type: "a", fields: %{"v" => 1}}], precision: :xx)
      end
    end

    test "integer field values and timestamps outside int64 raise value-free (the server 204s and SILENTLY DROPS the line — probed both signs)" do
      int64_max = 9_223_372_036_854_775_807
      int64_min = -9_223_372_036_854_775_808

      # Both boundaries PASS (the live T7 probe writes int64_max — don't break it).
      expected = stub_write("a v=#{int64_max}i #{int64_max}")

      assert :ok =
               TimeSeries.write(conn(), [
                 %{type: "a", fields: %{"v" => int64_max}, timestamp: int64_max}
               ])

      assert_received {:lines, body}
      assert IO.iodata_to_binary(body) == expected

      expected_min = stub_write("a v=#{int64_min}i #{int64_min}")

      assert :ok =
               TimeSeries.write(conn(), [
                 %{type: "a", fields: %{"v" => int64_min}, timestamp: int64_min}
               ])

      assert_received {:lines, body_min}
      assert IO.iodata_to_binary(body_min) == expected_min

      # One past the boundary raises value-free, BOTH signs, BOTH positions.
      for bad <- [int64_max + 1, int64_min - 1] do
        err =
          assert_raise ArgumentError, fn ->
            TimeSeries.write(conn(), [%{type: "a", fields: %{"v" => bad}}])
          end

        assert err.message == "integer field values must fit int64"
        refute Exception.message(err) =~ "#{abs(bad)}"

        err2 =
          assert_raise ArgumentError, fn ->
            TimeSeries.write(conn(), [%{type: "a", fields: %{"v" => 1}, timestamp: bad}])
          end

        assert err2.message == "timestamps must fit int64"
        refute Exception.message(err2) =~ "#{abs(bad)}"
      end
    end

    test "a DateTime timestamp whose converted value overflows int64 raises value-free (year 2263+ at :ns)" do
      # ~U[2263-01-01 00:00:00Z] at :nanosecond is 9.246e18 > int64_max — DateTime CAN overflow.
      err =
        assert_raise ArgumentError, fn ->
          TimeSeries.write(conn(), [
            %{type: "a", fields: %{"v" => 1}, timestamp: ~U[2263-01-01 00:00:00Z]}
          ])
        end

      assert err.message == "timestamps must fit int64"

      # The same DateTime at :s precision fits — the conversion unit decides.
      expected = stub_write("a v=1i 9246182400", "precision=s")

      assert :ok =
               TimeSeries.write(
                 conn(),
                 [%{type: "a", fields: %{"v" => 1}, timestamp: ~U[2263-01-01 00:00:00Z]}],
                 precision: :s
               )

      assert_received {:lines, body}
      assert IO.iodata_to_binary(body) == expected
    end

    test "control bytes are rejected value-free in tag values and string fields (record-split hazard)" do
      err =
        assert_raise ArgumentError, fn ->
          TimeSeries.write(conn(), [
            %{type: "a", tags: %{"k" => "in\njected"}, fields: %{"v" => 1}}
          ])
        end

      refute Exception.message(err) =~ "jected"

      err2 =
        assert_raise ArgumentError, fn ->
          TimeSeries.write(conn(), [%{type: "a", fields: %{"msg" => "se\ncret"}}])
        end

      refute Exception.message(err2) =~ "cret"
    end

    test "invalid UTF-8 in tag values and string fields is rejected value-free" do
      assert_raise ArgumentError, ~r/UTF-8/, fn ->
        TimeSeries.write(conn(), [%{type: "a", tags: %{"k" => <<0xFF>>}, fields: %{"v" => 1}}])
      end

      assert_raise ArgumentError, ~r/UTF-8/, fn ->
        TimeSeries.write(conn(), [%{type: "a", fields: %{"msg" => <<0xFF>>}}])
      end
    end

    test "a non-String.Chars tag/field KEY is {:error, :invalid_identifier} — never a Protocol.UndefinedError echoing the key" do
      assert {:error, :invalid_identifier} =
               TimeSeries.write(conn(), [
                 %{type: "a", tags: %{{:a, "leakkey"} => "x"}, fields: %{"v" => 1}}
               ])

      assert {:error, :invalid_identifier} =
               TimeSeries.write(conn(), [%{type: "a", fields: %{{:a, "leakkey"} => 1}}])
    end

    test "an empty tag VALUE is rejected value-free (would emit an invalid `,k=` line)" do
      assert_raise ArgumentError, ~r/non-empty/, fn ->
        TimeSeries.write(conn(), [%{type: "a", tags: %{"k" => ""}, fields: %{"v" => 1}}])
      end
    end

    test "an atom key colliding with its string twin is rejected (the name would emit twice)" do
      assert_raise ArgumentError, ~r/duplicate/, fn ->
        TimeSeries.write(conn(), [
          %{type: "a", tags: %{:h => "x", "h" => "y"}, fields: %{"v" => 1}}
        ])
      end

      assert_raise ArgumentError, ~r/duplicate/, fn ->
        TimeSeries.write(conn(), [%{type: "a", fields: %{:v => 1, "v" => 2}}])
      end
    end

    test "shape violations raise value-free; bad names return {:error, :invalid_identifier}" do
      assert_raise ArgumentError, ~r/points must be a list/, fn ->
        TimeSeries.write(conn(), %{type: "a", fields: %{"v" => 1}})
      end

      err =
        assert_raise ArgumentError, fn ->
          TimeSeries.write(conn(), [%{type: "a", fields: %{}}])
        end

      assert Exception.message(err) =~ "at least one field"

      err2 = assert_raise ArgumentError, fn -> TimeSeries.write(conn(), ["not-a-map-secret"]) end
      refute Exception.message(err2) =~ "secret"

      err3 =
        assert_raise ArgumentError, fn ->
          TimeSeries.write(conn(), [%{type: "a", fields: %{"v" => {:tuple, "leak"}}}])
        end

      refute Exception.message(err3) =~ "leak"

      assert {:error, :invalid_identifier} =
               TimeSeries.write(conn(), [%{type: "bad type", fields: %{"v" => 1}}])

      assert {:error, :invalid_identifier} =
               TimeSeries.write(conn(), [%{type: "a", fields: %{"bad field" => 1}}])

      assert {:error, :invalid_identifier} =
               TimeSeries.write(conn(), [
                 %{type: "a", tags: %{"bad tag" => "x"}, fields: %{"v" => 1}}
               ])
    end

    test "empty points list returns :ok without hitting the wire" do
      Req.Test.stub(__MODULE__, fn _c -> flunk("no wire call expected") end)
      assert :ok = TimeSeries.write(conn(), [])
    end

    test "a transport without ts_write is :not_supported (per-callback capability check)" do
      bolt_conn =
        Conn.new("bolt://h", "tsdb",
          auth: {"u", "p"},
          transport: Arcadic.Transport.Bolt,
          transport_options: [username: "u", password: "p"]
        )

      assert {:error, %Error{reason: :not_supported}} =
               TimeSeries.write(bolt_conn, [%{type: "a", fields: %{"v" => 1}}])
    end

    test "write_lines/3 rejects deep-invalid iodata value-free (would crash inside the HTTP client with the batch in the blame)" do
      err =
        assert_raise ArgumentError, fn ->
          TimeSeries.write_lines(conn(), ["m,t=x v=1.0 SENTINEL_LINE", :SENTINEL_ATOM])
        end

      assert err.message == "lines must be valid iodata"
      refute Exception.message(err) =~ "SENTINEL_LINE"
      refute Exception.message(err) =~ "SENTINEL_ATOM"

      err2 = assert_raise ArgumentError, fn -> TimeSeries.write_lines(conn(), ["line", nil]) end
      assert err2.message == "lines must be valid iodata"

      err3 = assert_raise ArgumentError, fn -> TimeSeries.write_lines(conn(), [999_999]) end
      assert err3.message == "lines must be valid iodata"

      # An improper list ([elem | :tail]) also fails the iodata probe — the F3 class for this entry.
      err4 =
        assert_raise ArgumentError, fn ->
          TimeSeries.write_lines(conn(), ["m v=1" | :SENTINEL_TAIL])
        end

      assert err4.message == "lines must be valid iodata"
      refute Exception.message(err4) =~ "SENTINEL_TAIL"
    end

    test "write_lines/3 empty-EQUIVALENT iodata short-circuits without hitting the wire" do
      Req.Test.stub(__MODULE__, fn _c -> flunk("no wire call expected") end)
      assert :ok = TimeSeries.write_lines(conn(), [""])
      assert :ok = TimeSeries.write_lines(conn(), [[]])
    end

    test "improper lists are rejected value-free at every list-walking public entry (F3)" do
      # create_type :fields (normalize_columns!/1)
      err =
        assert_raise ArgumentError, fn ->
          TimeSeries.create_type(conn(), "cpu", "ts", fields: [{:v, "DOUBLE"} | :SENTINEL_TAIL])
        end

      assert err.message == "columns must be a proper list"
      refute Exception.message(err) =~ "SENTINEL_TAIL"

      # write points walk (build_lines/2)
      err2 =
        assert_raise ArgumentError, fn ->
          TimeSeries.write(conn(), [%{type: "a", fields: %{"v" => 1}} | :SENTINEL_TAIL])
        end

      assert err2.message == "points must be a proper list"
      refute Exception.message(err2) =~ "SENTINEL_TAIL"

      # query :fields (query_fields/1)
      err3 =
        assert_raise ArgumentError, fn ->
          TimeSeries.query(conn(), "cpu", fields: ["a" | :SENTINEL_TAIL])
        end

      assert err3.message == "fields must be a proper list"
      refute Exception.message(err3) =~ "SENTINEL_TAIL"

      # query :aggregation (aggregation_object/2 requests walk)
      err4 =
        assert_raise ArgumentError, fn ->
          TimeSeries.query(conn(), "cpu",
            aggregation: [%{field: "u", type: :avg} | :SENTINEL_TAIL],
            bucket_interval: 1
          )
        end

      assert err4.message == "aggregation must be a proper list"
      refute Exception.message(err4) =~ "SENTINEL_TAIL"

      # prom_series :matches (Enum.all? walk)
      err5 =
        assert_raise ArgumentError, fn ->
          TimeSeries.prom_series(conn(), ["cpu" | :SENTINEL_TAIL])
        end

      assert err5.message == "matches must be a proper list"
      refute Exception.message(err5) =~ "SENTINEL_TAIL"
    end

    test "write_lines/3 passes raw lines through; non-binary/iodata raises value-free" do
      expected = stub_write("raw,t=1 v=1 9")
      assert :ok = TimeSeries.write_lines(conn(), "raw,t=1 v=1 9")
      assert_received {:lines, body}
      assert IO.iodata_to_binary(body) == expected

      err = assert_raise ArgumentError, fn -> TimeSeries.write_lines(conn(), %{secret: "x"}) end
      refute Exception.message(err) =~ "secret"
    end

    test "write emits the :timeseries telemetry span with row_count" do
      handler_id = "ts-write-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:arcadic, :timeseries, :stop],
        fn _e, _m, meta, pid -> send(pid, {:span_meta, meta}) end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      stub_write("a v=1i")
      assert :ok = TimeSeries.write(conn(), [%{type: "a", fields: %{"v" => 1}}])
      assert_received {:span_meta, %{operation: :write, mode: :write, row_count: 1}}
    end
  end

  describe "query/3 and latest/3" do
    alias Arcadic.TimeSeries

    defp stub_ts_query(expected_body, response) do
      Req.Test.stub(__MODULE__, fn c ->
        assert c.request_path == "/api/v1/ts/tsdb/query"
        {:ok, body, _} = Plug.Conn.read_body(c)
        assert Jason.decode!(body) == expected_body
        Req.Test.json(c, response)
      end)
    end

    test "raw query: from/to as epoch-ms ints or DateTime, fields, AND-tags, limit" do
      stub_ts_query(
        %{
          "type" => "cpu",
          "from" => 1_700_000_000_000,
          "to" => 1_700_000_360_000,
          "fields" => ["usage"],
          "tags" => %{"host" => "a", "region" => "eu"},
          "limit" => 10
        },
        %{"type" => "cpu", "columns" => ["ts", "usage"], "rows" => [[1, 2.0]], "count" => 1}
      )

      assert {:ok, %{columns: ["ts", "usage"], rows: [[1, 2.0]], count: 1}} =
               TimeSeries.query(conn(), "cpu",
                 from: 1_700_000_000_000,
                 to: DateTime.from_unix!(1_700_000_360_000, :millisecond),
                 fields: ["usage"],
                 tags: %{"host" => "a", "region" => "eu"},
                 limit: 10
               )
    end

    test "aggregated query shapes {bucketInterval, requests} with UPPERCASE allowlisted types" do
      stub_ts_query(
        %{
          "type" => "cpu",
          "aggregation" => %{
            "bucketInterval" => 3_600_000,
            "requests" => [%{"field" => "usage", "type" => "AVG", "alias" => "au"}]
          }
        },
        %{
          "type" => "cpu",
          "aggregations" => ["au"],
          "buckets" => [%{"timestamp" => 1, "values" => [2.0]}],
          "count" => 1
        }
      )

      assert {:ok, %{aggregations: ["au"], buckets: [%{timestamp: 1, values: [2.0]}], count: 1}} =
               TimeSeries.query(conn(), "cpu",
                 aggregation: [%{field: "usage", type: :avg, alias: "au"}],
                 bucket_interval: {1, :hours}
               )
    end

    test "aggregation guards: off-allowlist type, missing bucket_interval, bad field — value-free" do
      assert_raise ArgumentError, ~r/aggregation type/, fn ->
        TimeSeries.query(conn(), "cpu",
          aggregation: [%{field: "u", type: :stddev}],
          bucket_interval: 1
        )
      end

      assert_raise ArgumentError, ~r/bucket_interval/, fn ->
        TimeSeries.query(conn(), "cpu", aggregation: [%{field: "u", type: :avg}])
      end

      assert {:error, :invalid_identifier} =
               TimeSeries.query(conn(), "cpu",
                 aggregation: [%{field: "bad field", type: :avg}],
                 bucket_interval: 1
               )
    end

    test "limit must be a positive integer (the server accepts -1 and returns count:-1 nonsense)" do
      assert_raise ArgumentError, ~r/limit/, fn -> TimeSeries.query(conn(), "cpu", limit: -1) end
      assert_raise ArgumentError, ~r/limit/, fn -> TimeSeries.query(conn(), "cpu", limit: 0) end
    end

    test "bad from/to and bad type are rejected" do
      assert_raise ArgumentError, ~r/from/, fn ->
        TimeSeries.query(conn(), "cpu", from: "2026-01-01")
      end

      assert {:error, :invalid_identifier} = TimeSeries.query(conn(), "bad type")
    end

    test "latest/3 sends type + at most ONE tag; a multi-tag request is rejected value-free" do
      Req.Test.stub(__MODULE__, fn c ->
        assert c.request_path == "/api/v1/ts/tsdb/latest"
        assert URI.decode_query(c.query_string) == %{"type" => "cpu", "tag" => "host:a"}
        Req.Test.json(c, %{"type" => "cpu", "columns" => ["ts", "v"], "latest" => [1, 2.0]})
      end)

      assert {:ok, %{columns: ["ts", "v"], latest: [1, 2.0]}} =
               TimeSeries.latest(conn(), "cpu", tag: {"host", "a"})

      # The substrate applies only the FIRST tag param, order-dependently (probed both orders on
      # 26.7.2) — a multi-tag map would be a NONDETERMINISTIC filter no-op, so >1 is rejected.
      assert_raise ArgumentError, ~r/single tag/, fn ->
        TimeSeries.latest(conn(), "cpu", tag: %{"host" => "a", "region" => "eu"})
      end

      assert {:error, :invalid_identifier} =
               TimeSeries.latest(conn(), "cpu", tag: {"bad key", "v"})

      err =
        assert_raise ArgumentError, fn ->
          TimeSeries.latest(conn(), "cpu", tag: {"host", :notbin})
        end

      refute Exception.message(err) =~ "notbin"
    end

    test "query!/latest! unwrap the value; capability check on a Bolt conn" do
      Req.Test.stub(__MODULE__, fn c ->
        Req.Test.json(c, %{"type" => "cpu", "columns" => [], "rows" => [], "count" => 0})
      end)

      assert %{rows: [], count: 0} = TimeSeries.query!(conn(), "cpu")

      bolt_conn =
        Conn.new("bolt://h", "tsdb",
          auth: {"u", "p"},
          transport: Arcadic.Transport.Bolt,
          transport_options: [username: "u", password: "p"]
        )

      assert {:error, %Error{reason: :not_supported}} = TimeSeries.query(bolt_conn, "cpu")
      assert {:error, %Error{reason: :not_supported}} = TimeSeries.latest(bolt_conn, "cpu")
    end

    test "query tags: an atom key colliding with its string twin is rejected (write-path parity)" do
      assert_raise ArgumentError, ~r/duplicate/, fn ->
        TimeSeries.query(conn(), "cpu", tags: %{:host => "a", "host" => "b"})
      end
    end

    test "query tags: atom keys convert; a non-binary tag VALUE raises value-free" do
      stub_ts_query(
        %{"type" => "cpu", "tags" => %{"host" => "a"}},
        %{"type" => "cpu", "columns" => ["ts"], "rows" => [], "count" => 0}
      )

      assert {:ok, %{count: 0}} = TimeSeries.query(conn(), "cpu", tags: %{host: "a"})

      err =
        assert_raise ArgumentError, fn ->
          TimeSeries.query(conn(), "cpu", tags: %{"host" => 42})
        end

      assert err.message == "tag values must be strings"
    end

    test "fields: an empty list and a non-name entry are rejected value-free" do
      assert_raise ArgumentError, ~r/fields/, fn ->
        TimeSeries.query(conn(), "cpu", fields: [])
      end

      err =
        assert_raise ArgumentError, fn ->
          TimeSeries.query(conn(), "cpu", fields: [{:secret, "leak"}])
        end

      refute Exception.message(err) =~ "leak"
    end

    test "bucket_interval without aggregation, a zero duration, and an empty request list are rejected" do
      assert_raise ArgumentError, ~r/bucket_interval/, fn ->
        TimeSeries.query(conn(), "cpu", bucket_interval: 3_600_000)
      end

      assert_raise ArgumentError, ~r/bucket_interval/, fn ->
        TimeSeries.query(conn(), "cpu",
          aggregation: [%{field: "u", type: :avg}],
          bucket_interval: {0, :hours}
        )
      end

      assert_raise ArgumentError, ~r/aggregation/, fn ->
        TimeSeries.query(conn(), "cpu", aggregation: [], bucket_interval: 1)
      end
    end

    test "duplicate aggregation OUTPUTS are rejected; distinct types on one field are fine" do
      # Colliding alias.
      assert_raise ArgumentError, ~r/duplicate aggregation output/, fn ->
        TimeSeries.query(conn(), "cpu",
          aggregation: [
            %{field: "a", type: :avg, alias: "x"},
            %{field: "b", type: :max, alias: "x"}
          ],
          bucket_interval: 1
        )
      end

      # Identical field+type pair, no alias.
      assert_raise ArgumentError, ~r/duplicate aggregation output/, fn ->
        TimeSeries.query(conn(), "cpu",
          aggregation: [%{field: "u", type: :avg}, %{field: "u", type: :avg}],
          bucket_interval: 1
        )
      end

      # NOT a collision: the server's default output name incorporates the type ("u_avg"/"u_max").
      stub_ts_query(
        %{
          "type" => "cpu",
          "aggregation" => %{
            "bucketInterval" => 1,
            "requests" => [
              %{"field" => "u", "type" => "AVG"},
              %{"field" => "u", "type" => "MAX"}
            ]
          }
        },
        %{"type" => "cpu", "aggregations" => ["u_avg", "u_max"], "buckets" => [], "count" => 0}
      )

      assert {:ok, %{count: 0}} =
               TimeSeries.query(conn(), "cpu",
                 aggregation: [%{field: "u", type: :avg}, %{field: "u", type: :max}],
                 bucket_interval: 1
               )
    end

    test "latest tag values: empty and colon-bearing values are rejected value-free (unprobed key:value micro-format)" do
      assert_raise ArgumentError, ~r/non-empty/, fn ->
        TimeSeries.latest(conn(), "cpu", tag: {"host", ""})
      end

      err =
        assert_raise ArgumentError, fn ->
          TimeSeries.latest(conn(), "cpu", tag: {"host", "secret:leak"})
        end

      refute Exception.message(err) =~ "secret"
      assert err.message =~ "colon"
    end

    test "query emits the :timeseries read span with row_count" do
      handler_id = "ts-read-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:arcadic, :timeseries, :stop],
        fn _e, _m, meta, pid -> send(pid, {:span_meta, meta}) end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Req.Test.stub(__MODULE__, fn c ->
        Req.Test.json(c, %{"type" => "cpu", "columns" => [], "rows" => [], "count" => 0})
      end)

      assert {:ok, %{count: 0}} = TimeSeries.query(conn(), "cpu")
      assert_received {:span_meta, %{operation: :query, mode: :read, row_count: 0}}
    end
  end

  describe "promql family" do
    alias Arcadic.TimeSeries

    defp stub_prom(expected_path, expected_query, data) do
      Req.Test.stub(__MODULE__, fn c ->
        assert c.request_path == expected_path
        assert URI.decode_query(c.query_string) == expected_query
        Req.Test.json(c, %{"status" => "success", "data" => data})
      end)
    end

    test "prom_query/3 instant with :time (int or DateTime, epoch-seconds)" do
      stub_prom(
        "/api/v1/ts/tsdb/prom/api/v1/query",
        %{"query" => "cpu{host=\"a\"}", "time" => "1700000000"},
        %{"resultType" => "vector", "result" => []}
      )

      assert {:ok, %{"resultType" => "vector"}} =
               TimeSeries.prom_query(conn(), "cpu{host=\"a\"}", time: 1_700_000_000)

      stub_prom(
        "/api/v1/ts/tsdb/prom/api/v1/query",
        %{"query" => "cpu", "time" => "1700000000"},
        %{"resultType" => "vector", "result" => []}
      )

      assert {:ok, _} =
               TimeSeries.prom_query(conn(), "cpu", time: DateTime.from_unix!(1_700_000_000))
    end

    test "prom_query_range/6 sends start/end/step (step: integer seconds or duration string)" do
      stub_prom(
        "/api/v1/ts/tsdb/prom/api/v1/query_range",
        %{"query" => "cpu", "start" => "100", "end" => "200", "step" => "60"},
        %{"resultType" => "matrix", "result" => []}
      )

      assert {:ok, %{"resultType" => "matrix"}} =
               TimeSeries.prom_query_range(conn(), "cpu", 100, 200, 60)

      stub_prom(
        "/api/v1/ts/tsdb/prom/api/v1/query_range",
        %{"query" => "cpu", "start" => "100", "end" => "200", "step" => "1m"},
        %{"resultType" => "matrix", "result" => []}
      )

      assert {:ok, _} = TimeSeries.prom_query_range(conn(), "cpu", 100, 200, "1m")
    end

    test "prom_labels/2, prom_label_values/3 (Prometheus label grammar admits __name__), prom_series/3" do
      stub_prom("/api/v1/ts/tsdb/prom/api/v1/labels", %{}, ["__name__", "host"])
      assert {:ok, ["__name__", "host"]} = TimeSeries.prom_labels(conn())

      stub_prom("/api/v1/ts/tsdb/prom/api/v1/label/__name__/values", %{}, ["cpu"])
      assert {:ok, ["cpu"]} = TimeSeries.prom_label_values(conn(), "__name__")

      assert_raise ArgumentError, ~r/label/, fn ->
        TimeSeries.prom_label_values(conn(), "bad-label!")
      end

      Req.Test.stub(__MODULE__, fn c ->
        assert c.request_path == "/api/v1/ts/tsdb/prom/api/v1/series"
        assert c.query_string == "match%5B%5D=cpu&match%5B%5D=mem"
        Req.Test.json(c, %{"status" => "success", "data" => []})
      end)

      assert {:ok, []} = TimeSeries.prom_series(conn(), ["cpu", "mem"])
      assert_raise ArgumentError, ~r/matches/, fn -> TimeSeries.prom_series(conn(), "cpu") end
    end

    test "prom_query/3 without :time omits the time param entirely" do
      stub_prom(
        "/api/v1/ts/tsdb/prom/api/v1/query",
        %{"query" => "cpu"},
        %{"resultType" => "vector", "result" => []}
      )

      assert {:ok, %{"resultType" => "vector"}} = TimeSeries.prom_query(conn(), "cpu")
    end

    test "empty PromQL, empty step string, step 0, and an empty match entry reject (static)" do
      assert_raise ArgumentError, ~r/non-empty/, fn -> TimeSeries.prom_query(conn(), "") end

      assert_raise ArgumentError, ~r/non-empty/, fn ->
        TimeSeries.prom_query_range(conn(), "cpu", 100, 200, "")
      end

      assert_raise ArgumentError, ~r/step/, fn ->
        TimeSeries.prom_query_range(conn(), "cpu", 100, 200, 0)
      end

      assert_raise ArgumentError, ~r/non-empty/, fn -> TimeSeries.prom_series(conn(), [""]) end
    end

    test "a non-integer/DateTime time raises value-free" do
      err =
        assert_raise ArgumentError, fn ->
          TimeSeries.prom_query(conn(), "cpu", time: 1.5)
        end

      refute Exception.message(err) =~ "1.5"
      assert err.message =~ "epoch-seconds"
    end

    test "every prom bang unwraps through its own wire op (swapped delegation goes red)" do
      stub_prom(
        "/api/v1/ts/tsdb/prom/api/v1/query",
        %{"query" => "cpu", "time" => "100"},
        %{"resultType" => "vector", "result" => []}
      )

      assert %{"resultType" => "vector"} = TimeSeries.prom_query!(conn(), "cpu", time: 100)

      stub_prom(
        "/api/v1/ts/tsdb/prom/api/v1/query_range",
        %{"query" => "cpu", "start" => "100", "end" => "200", "step" => "60"},
        %{"resultType" => "matrix", "result" => []}
      )

      assert %{"resultType" => "matrix"} =
               TimeSeries.prom_query_range!(conn(), "cpu", 100, 200, 60)

      stub_prom("/api/v1/ts/tsdb/prom/api/v1/label/host/values", %{}, ["a", "b"])
      assert ["a", "b"] = TimeSeries.prom_label_values!(conn(), "host")

      stub_prom(
        "/api/v1/ts/tsdb/prom/api/v1/series",
        %{"match[]" => "cpu"},
        [%{"__name__" => "cpu"}]
      )

      assert [%{"__name__" => "cpu"}] = TimeSeries.prom_series!(conn(), ["cpu"])
    end

    test "prom reads emit the :timeseries read span with row_count from the list envelope" do
      handler_id = "ts-prom-read-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:arcadic, :timeseries, :stop],
        fn _e, _m, meta, pid -> send(pid, {:span_meta, meta}) end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      stub_prom("/api/v1/ts/tsdb/prom/api/v1/labels", %{}, ["__name__", "host", "region"])
      assert {:ok, [_, _, _]} = TimeSeries.prom_labels(conn())
      assert_received {:span_meta, %{operation: :prom_labels, mode: :read, row_count: 3}}
    end

    test "non-binary promql raises value-free; capability check; bang unwraps" do
      err = assert_raise ArgumentError, fn -> TimeSeries.prom_query(conn(), %{secret: "q"}) end
      refute Exception.message(err) =~ "secret"

      bolt_conn =
        Conn.new("bolt://h", "tsdb",
          auth: {"u", "p"},
          transport: Arcadic.Transport.Bolt,
          transport_options: [username: "u", password: "p"]
        )

      assert {:error, %Error{reason: :not_supported}} = TimeSeries.prom_labels(bolt_conn)

      stub_prom("/api/v1/ts/tsdb/prom/api/v1/labels", %{}, ["host"])
      assert ["host"] = TimeSeries.prom_labels!(conn())
    end
  end
end
