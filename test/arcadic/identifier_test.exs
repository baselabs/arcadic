defmodule Arcadic.IdentifierTest do
  use ExUnit.Case, async: true
  alias Arcadic.Identifier

  describe "validate/1" do
    test "accepts a valid identifier" do
      assert Identifier.validate("commercegraph") == :ok
      assert Identifier.validate("User_2") == :ok
      assert Identifier.validate("A") == :ok
    end

    test "rejects the empty string" do
      assert Identifier.validate("") == {:error, :invalid_identifier}
    end

    test "rejects a leading digit" do
      assert Identifier.validate("2fast") == {:error, :invalid_identifier}
    end

    test "rejects dots, spaces, and injection punctuation" do
      for bad <- ["db.name", "a b", "drop database x", "a;b", "a-b", "a/b"] do
        assert Identifier.validate(bad) == {:error, :invalid_identifier},
               "expected reject: #{bad}"
      end
    end

    test "rejects non-ASCII" do
      assert Identifier.validate("café") == {:error, :invalid_identifier}
    end

    test "rejects an over-long identifier (129 chars)" do
      assert Identifier.validate("a" <> String.duplicate("b", 128)) ==
               {:error, :invalid_identifier}
    end

    test "accepts a 128-char identifier (boundary)" do
      assert Identifier.validate("a" <> String.duplicate("b", 127)) == :ok
    end

    test "rejects a non-binary" do
      assert Identifier.validate(nil) == {:error, :invalid_identifier}
    end

    test "rejects newline-bearing identifiers (locks the \\A...\\z anchor)" do
      assert Identifier.validate("good\n") == {:error, :invalid_identifier}
      assert Identifier.validate("a\nb") == {:error, :invalid_identifier}
    end
  end

  describe "valid?/1" do
    test "mirrors validate/1 as a boolean" do
      assert Identifier.valid?("ok_name")
      refute Identifier.valid?("bad.name")
    end
  end
end
