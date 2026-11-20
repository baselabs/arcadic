# The Bolt transport exists only where DBConnection is present;
# the condition is the one lib/arcadic/transport/bolt.ex compiles under.
if Code.ensure_loaded?(DBConnection) do
  defmodule Arcadic.Transport.Bolt.QueryStreamTest do
    use ExUnit.Case, async: true
    alias Arcadic.{Conn, Transport.Bolt}
    alias Arcadic.Transport.Bolt.Client
    alias Arcadic.Transport.Bolt.Types.{Duration, Point}

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

      test "format_params/1 preserves native Duration/Point values for PackStream" do
        dur = %Duration{days: 1, seconds: 7384}
        point = %Point{srid: 7203, x: 10.0, y: 20.0}
        assert Bolt.format_params(%{"d" => dur, "p" => point}) == %{"d" => dur, "p" => point}
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
      test "passes through ok and tags an intentional rollback (unwrapped to {:error, reason} by transaction/3)" do
        assert Bolt.map_transaction_outcome({:ok, 42}) == {:ok, 42}

        # A deliberate abort is tagged {:__rollback__, reason} so the managed-retry loop treats it as
        # terminal (D7); Arcadic.Transaction.transaction/3 unwraps it to the public {:error, reason}.
        assert Bolt.map_transaction_outcome({:error, {:arcadic_rollback, :nope}}) ==
                 {:__rollback__, :nope}
      end

      test "maps DBConnection's bare :rollback commit-failure to a typed error" do
        assert {:error, %Arcadic.Error{reason: :transaction_error}} =
                 Bolt.map_transaction_outcome({:error, :rollback})
      end

      test "maps a Arcadic.Error via the reason taxonomy" do
        e = %Arcadic.Error{
          reason: :parse_error,
          exception: "Neo.ClientError.Statement.SyntaxError"
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
      test "maps a wire timeout to a typed transport :timeout error" do
        assert Bolt.stream_error(%Arcadic.TransportError{reason: :timeout}) ==
                 %Arcadic.TransportError{reason: :timeout}
      end

      test "maps a bare socket atom (e.g. :closed) to a typed transport error" do
        assert Bolt.stream_error(:closed) == %Arcadic.TransportError{reason: :closed}
      end

      test "a value-bearing server error redacts: sentinel in neither message/1 nor inspect" do
        sentinel = "row-value-and-email@example.com-SEKRET"

        e = %Arcadic.Error{
          reason: :parse_error,
          exception: "Neo.ClientError.Statement.SyntaxError",
          message: sentinel
        }

        err = Client.failure(%{"code" => e.exception, "message" => sentinel})
        assert %Arcadic.Error{reason: :parse_error} = err
        # The value-bearing bolt.message must not survive into the raised exception.
        refute Exception.message(err) =~ sentinel
        refute inspect(err) =~ sentinel
      end
    end

    describe "Bolt.exec_opts/1 (db_connection opts threading)" do
      test "threads :timeout through to prepare_execute and drops arcadic-only opts" do
        # Before the fix, execute/4 + explain/3 hardcoded `[]`, so a caller's :timeout was accepted by
        # the facade then silently dropped on Bolt. exec_opts forwards :timeout — and ONLY db_connection
        # opts — into DBConnection.prepare_execute/4 (arcadic opts like :language/:limit must not leak).
        assert Bolt.exec_opts(timeout: 2_500, language: "cypher", limit: 5) == [timeout: 2_500]
      end

      test "is empty when the caller omits :timeout (db_connection keeps its own default)" do
        assert Bolt.exec_opts(language: "cypher") == []
        assert Bolt.exec_opts([]) == []
      end
    end

    describe "Bolt.transport_reason/1 (preserve the typed reason, don't collapse to the module)" do
      test "surfaces the :reason of an already-typed TransportError (e.g. :cursor_open)" do
        # The tx cursor-desync guard (Connection.handle_execute) fails closed with
        # %TransportError{reason: :cursor_open}; db_connection surfaces it to execute/4's `{:error,
        # other}` branch. Before the fix this collapsed to `reason: Arcadic.TransportError` (the MODULE),
        # losing :cursor_open. Composes with bolt_connection_test.exs (which proves handle_execute
        # PRODUCES :cursor_open) to prove the end-to-end query/explain surfacing — the mid-cursor state
        # is not reliably reachable through the public Stream API (halting to issue a query deallocates
        # the cursor first), so the guard is verified at the unit level as the existing suite does.
        assert Bolt.transport_reason(%Arcadic.TransportError{reason: :cursor_open}) ==
                 :cursor_open
      end

      test "surfaces the :reason of an already-typed Arcadic.Error" do
        assert Bolt.transport_reason(%Arcadic.Error{reason: :parse_error}) == :parse_error
      end

      test "falls back to the struct MODULE for a raw db_connection exception (unchanged)" do
        assert Bolt.transport_reason(%RuntimeError{message: "x"}) == RuntimeError
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
  end
end
