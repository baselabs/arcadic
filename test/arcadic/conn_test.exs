defmodule Arcadic.ConnTest do
  use ExUnit.Case, async: true
  doctest Arcadic.Conn
  alias Arcadic.{Conn, Transport}

  describe "new/3" do
    test "builds a conn with defaults and a trimmed base_url" do
      conn = Conn.new("http://localhost:2480/", "mydb", auth: {"root", "sekret"})
      assert conn.base_url == "http://localhost:2480"
      assert conn.database == "mydb"
      assert conn.auth == {"root", "sekret"}
      assert conn.session_id == nil
      assert conn.transport == Arcadic.Transport.HTTP
      assert conn.transport_options == []
    end

    test "requires auth — raises with a value-free message when missing" do
      err = assert_raise ArgumentError, fn -> Conn.new("http://localhost:2480", "mydb") end
      refute String.contains?(Exception.message(err), "root")
    end

    test "validates the database identifier" do
      assert_raise ArgumentError, fn ->
        Conn.new("http://localhost:2480", "bad.name", auth: {"root", "x"})
      end
    end

    test "carries transport_options and timeout" do
      conn =
        Conn.new("http://localhost:2480", "mydb",
          auth: {"root", "x"},
          transport_options: [finch: MyFinch],
          timeout: 30_000
        )

      assert conn.transport_options == [finch: MyFinch]
      assert conn.timeout == 30_000
    end
  end

  describe "with_database/2" do
    setup do
      %{conn: Conn.new("http://localhost:2480", "db1", auth: {"root", "x"})}
    end

    test "derives a conn on another database and clears the session", %{conn: conn} do
      tx = %{conn | session_id: "AS-123"}
      conn2 = Conn.with_database(tx, "db2")
      assert conn2.database == "db2"
      assert conn2.session_id == nil
    end

    test "validates the new identifier", %{conn: conn} do
      assert_raise ArgumentError, fn -> Conn.with_database(conn, "db 2") end
    end
  end

  describe "Inspect redaction" do
    test "never renders the password or a session id" do
      conn = %{
        Conn.new("http://localhost:2480", "mydb", auth: {"root", "sekret"})
        | session_id: "AS-secret"
      }

      rendered = inspect(conn)
      refute rendered =~ "sekret"
      refute rendered =~ "AS-secret"
      assert rendered =~ "[REDACTED]"
    end
  end

  describe "bearer auth (G7)" do
    test "auth {:bearer, token} + HTTP transport is accepted; with_bearer derives it" do
      conn = Conn.new("http://a.invalid", "db", auth: {"root", "x"})
      bearer = Conn.with_bearer(conn, "AU-tok")
      assert bearer.auth == {:bearer, "AU-tok"}
      assert bearer.session_id == nil
    end

    test "headers/1 emits Bearer for a bearer conn and Basic for a tuple conn (bearer-first)" do
      bearer = Conn.new("http://a.invalid", "db", auth: {:bearer, "AU-tok"})
      assert {"authorization", "Bearer AU-tok"} in Transport.HTTP.headers(bearer)
      basic = Conn.new("http://a.invalid", "db", auth: {"root", "x"})

      assert {"authorization", "Basic " <> _} =
               List.keyfind(Transport.HTTP.headers(basic), "authorization", 0)
    end

    test "Inspect redacts a bearer token" do
      refute inspect(Conn.new("http://a.invalid", "db", auth: {:bearer, "AU-secret"})) =~
               "AU-secret"
    end

    test "bearer auth is rejected value-free for the Bolt transport (new/3 and with_bearer/2)" do
      assert_raise ArgumentError, ~r/bearer auth requires the HTTP transport/, fn ->
        Conn.new("http://a.invalid", "db",
          auth: {:bearer, "AU-tok"},
          transport: Arcadic.Transport.Bolt
        )
      end

      bolt_conn =
        Conn.new("http://a.invalid", "db", auth: {"root", "x"}, transport: Arcadic.Transport.Bolt)

      assert_raise ArgumentError, ~r/bearer auth requires the HTTP transport/, fn ->
        Conn.with_bearer(bolt_conn, "AU-tok")
      end

      # Rule 3: the raised message never echoes the token
      e = assert_raise ArgumentError, fn -> Conn.with_bearer(bolt_conn, "AU-secret") end
      refute Exception.message(e) =~ "AU-secret"
    end

    test "with_bearer/2 rejects a non-binary token value-free (no FunctionClauseError blame echo)" do
      # The classic footgun: a charlist token instead of a binary. Without a fallback clause this
      # FunctionClauseErrors, echoing the token in the blame (a Rule-3 secret leak). Must raise a
      # value-free ArgumentError instead.
      conn = Conn.new("http://a.invalid", "db", auth: {"root", "x"})
      e = assert_raise ArgumentError, fn -> Conn.with_bearer(conn, ~c"AU-secret-tok") end
      refute Exception.message(e) =~ "AU-secret-tok"
      refute Exception.message(e) =~ "secret"
    end
  end

  describe "read-consistency + hosts (S10 G14)" do
    test "defaults: consistency :eventual, read_after nil, hosts []" do
      conn = Conn.new("http://a.invalid", "db", auth: {"root", "x"})
      assert conn.consistency == :eventual
      assert conn.read_after == nil
      assert conn.hosts == []
    end

    test "connect accepts :consistency and :hosts" do
      conn =
        Conn.new("http://a.invalid", "db",
          auth: {"root", "x"},
          consistency: :read_your_writes,
          hosts: ["http://b.invalid", "http://c.invalid/"]
        )

      assert conn.consistency == :read_your_writes
      assert conn.hosts == ["http://b.invalid", "http://c.invalid"]
    end

    test "with_consistency/2 derives a level and clears the session, value-free on a bad level" do
      conn = %{Conn.new("http://a.invalid", "db", auth: {"root", "x"}) | session_id: "AS-1"}
      lin = Conn.with_consistency(conn, :linearizable)
      assert lin.consistency == :linearizable
      assert lin.session_id == nil

      e = assert_raise ArgumentError, fn -> Conn.with_consistency(conn, :bogus) end
      # value-free: the offending level is never echoed, but the allowed set is
      refute Exception.message(e) =~ "bogus"
      assert Exception.message(e) =~ "read_your_writes"
    end

    test "invalid :consistency at connect raises value-free" do
      e =
        assert_raise ArgumentError, fn ->
          Conn.new("http://a.invalid", "db", auth: {"root", "x"}, consistency: :nope)
        end

      assert Exception.message(e) =~ "eventual"
    end

    test "malformed :hosts entries are rejected value-free at construction" do
      assert_raise ArgumentError, ~r/host/, fn ->
        Conn.new("http://a.invalid", "db", auth: {"root", "x"}, hosts: ["not-a-url"])
      end

      assert_raise ArgumentError, ~r/host/, fn ->
        Conn.new("http://a.invalid", "db", auth: {"root", "x"}, hosts: [:notabinary])
      end
    end

    test "Bolt rejects a non-default consistency and a non-empty hosts list value-free" do
      assert_raise ArgumentError, ~r/HTTP transport/, fn ->
        Conn.new("http://a.invalid", "db",
          auth: {"root", "x"},
          transport: Arcadic.Transport.Bolt,
          consistency: :linearizable
        )
      end

      assert_raise ArgumentError, ~r/HTTP transport/, fn ->
        Conn.new("http://a.invalid", "db",
          auth: {"root", "x"},
          transport: Arcadic.Transport.Bolt,
          hosts: ["http://b.invalid"]
        )
      end

      ok =
        Conn.new("http://a.invalid", "db", auth: {"root", "x"}, transport: Arcadic.Transport.Bolt)

      assert ok.consistency == :eventual

      bolt =
        Conn.new("http://a.invalid", "db", auth: {"root", "x"}, transport: Arcadic.Transport.Bolt)

      assert_raise ArgumentError, ~r/HTTP transport/, fn ->
        Conn.with_consistency(bolt, :linearizable)
      end
    end
  end
end
