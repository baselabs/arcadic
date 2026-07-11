defmodule Arcadic.DDLBodyTest do
  use ExUnit.Case, async: true
  alias Arcadic.DDLBody

  describe "encode/1 — accepts embeddable bodies" do
    test "a valid single-line single-quoted body round-trips" do
      assert DDLBody.encode("var s='hi'; return s") == {:ok, "var s='hi'; return s"}
    end

    test "non-ASCII printable is allowed (no ASCII narrowing)" do
      assert DDLBody.encode("café ") == {:ok, "café "}
    end
  end

  describe "encode/1 — rejects unembeddable bytes value-free" do
    test "a double-quote (the sole breakout byte) is rejected" do
      assert DDLBody.encode(~s|has "dquote"|) == {:error, :unencodable_body}
    end

    test "a backslash is rejected (parse-errors server-side)" do
      assert DDLBody.encode("a\\b") == {:error, :unencodable_body}
    end

    test "a newline is rejected (parse-errors server-side)" do
      assert DDLBody.encode("line1\nline2") == {:error, :unencodable_body}
    end

    test "a control byte (NUL) is rejected" do
      assert DDLBody.encode("nul\0") == {:error, :unencodable_body}
    end

    test "a secret-in-body case rejects with a bare atom — no value echo" do
      # The reject is a bare atom (inherently value-free); the secret cannot leak.
      assert DDLBody.encode(~s|k="SECRET"|) == {:error, :unencodable_body}
    end

    test "an invalid-UTF-8 binary rejects cleanly (no opaque :re raise)" do
      # Satisfies is_binary but is not valid UTF-8; must NOT raise on the /u-flag Regex.match?.
      assert DDLBody.encode(<<0xFF, 0xFE, ?">>) == {:error, :unencodable_body}
    end
  end

  describe "encode/1 — contract pins" do
    test "an empty body is allowed (byte-level guard; emptiness is the consumer's concern)" do
      assert DDLBody.encode("") == {:ok, ""}
    end
  end

  describe "encode/1 — wrong type raises value-free (Rule 3)" do
    test "a non-binary integer body raises ArgumentError without echoing the value" do
      err = assert_raise ArgumentError, fn -> DDLBody.encode(123) end
      assert Exception.message(err) == "body must be a string"
      refute Exception.message(err) =~ "123"
    end

    test "a nil body raises ArgumentError value-free" do
      err = assert_raise ArgumentError, fn -> DDLBody.encode(nil) end
      assert Exception.message(err) == "body must be a string"
      refute Exception.message(err) =~ "nil"
    end
  end
end
