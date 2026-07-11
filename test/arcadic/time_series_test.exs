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
end
