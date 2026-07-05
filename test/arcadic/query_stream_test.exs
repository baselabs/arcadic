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
    test "refuses a session/tx conn (defense in depth)" do
      conn = %{bolt_conn() | session_id: "bolt", transport_options: [bolt_opts: []]}

      assert {:error,
              %Arcadic.Error{
                reason: :not_supported,
                message: "streaming is not available inside a transaction"
              }} =
               Bolt.query_stream(
                 conn,
                 %{statement: "RETURN 1", params: %{}, language: "cypher"},
                 []
               )
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
    test "returns :not_supported on the HTTP transport" do
      conn = Conn.new("http://localhost:2480", "db", auth: {"u", "p"})

      assert {:error,
              %Arcadic.Error{
                reason: :not_supported,
                message: "transport does not support streaming"
              }} =
               Arcadic.query_stream(conn, "MATCH (n) RETURN n")
    end

    test "returns :not_supported inside a transaction (session_id set)" do
      conn = %{bolt_conn() | session_id: "bolt"}

      assert {:error,
              %Arcadic.Error{
                reason: :not_supported,
                message: "streaming is not available inside a transaction"
              }} =
               Arcadic.query_stream(conn, "MATCH (n) RETURN n")
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
end
