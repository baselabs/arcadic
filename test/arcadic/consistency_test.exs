defmodule Arcadic.ConsistencyTest do
  use ExUnit.Case, async: true
  alias Arcadic.{Conn, Transport}

  defp hdrs(conn), do: Map.new(Transport.HTTP.headers(conn))

  test ":eventual (default) emits NO read-consistency headers (byte-identical to today)" do
    conn = Conn.new("http://a.invalid", "db", auth: {"root", "x"})
    h = hdrs(conn)
    refute Map.has_key?(h, "x-arcadedb-read-consistency")
    refute Map.has_key?(h, "x-arcadedb-read-after")
  end

  test ":linearizable emits the lowercase level header, no read-after" do
    conn = Conn.new("http://a.invalid", "db", auth: {"root", "x"}, consistency: :linearizable)
    h = hdrs(conn)
    assert h["x-arcadedb-read-consistency"] == "linearizable"
    refute Map.has_key?(h, "x-arcadedb-read-after")
  end

  test "read_your_writes with a bookmark emits BOTH headers, and read_after is stringified" do
    conn = %{
      Conn.new("http://a.invalid", "db", auth: {"root", "x"}, consistency: :read_your_writes)
      | read_after: 42
    }

    h = hdrs(conn)
    assert h["x-arcadedb-read-consistency"] == "read_your_writes"
    assert h["x-arcadedb-read-after"] == "42"
  end

  test "read_your_writes with a nil bookmark (single-server) sends the level but no read-after" do
    conn = Conn.new("http://a.invalid", "db", auth: {"root", "x"}, consistency: :read_your_writes)
    h = hdrs(conn)
    assert h["x-arcadedb-read-consistency"] == "read_your_writes"
    refute Map.has_key?(h, "x-arcadedb-read-after")
  end

  test "consistency headers attach for a BEARER conn too (both auth clauses)" do
    conn = %{
      Conn.new("http://a.invalid", "db",
        auth: {:bearer, "AU-tok"},
        consistency: :read_your_writes
      )
      | read_after: 7
    }

    h = hdrs(conn)
    assert h["authorization"] == "Bearer AU-tok"
    assert h["x-arcadedb-read-consistency"] == "read_your_writes"
    assert h["x-arcadedb-read-after"] == "7"
  end
end
