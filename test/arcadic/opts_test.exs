defmodule Arcadic.OptsTest do
  use ExUnit.Case, async: true
  alias Arcadic.Opts

  test "returns :ok when every key is allowed (incl. the empty list)" do
    assert :ok = Opts.validate_keys!([], [:type])
    assert :ok = Opts.validate_keys!([type: "T"], [:type])
    assert :ok = Opts.validate_keys!([with: [], type: 1], [:with, :type])
  end

  test "rejects an unknown key — echoes only the option NAME, never a caller value" do
    err =
      assert_raise ArgumentError, fn ->
        Opts.validate_keys!([typ: "SENTINEL_VALUE_9f3a"], [:type])
      end

    assert err.message =~ "unknown option"
    assert err.message =~ ":typ"
    refute err.message =~ "SENTINEL_VALUE_9f3a"
  end

  test "rejects a non-keyword opts value-free, never echoing the offending entry (Rule 3)" do
    # a map
    err_map = assert_raise ArgumentError, fn -> Opts.validate_keys!(%{type: "x"}, [:type]) end
    assert err_map.message == "opts must be a keyword list"

    # an improper list whose bare entry carries a sentinel — Keyword.keys/1 would echo it
    err_atom =
      assert_raise ArgumentError, fn -> Opts.validate_keys!([:SENTINEL_SECRET_9f3a], [:type]) end

    assert err_atom.message == "opts must be a keyword list"
    refute err_atom.message =~ "SENTINEL_SECRET_9f3a"

    # a non-two-tuple / non-atom-keyed entry carrying a sentinel value
    err_tuple =
      assert_raise ArgumentError, fn -> Opts.validate_keys!([{"SENTINEL_9f3a", 1}], [:type]) end

    assert err_tuple.message == "opts must be a keyword list"
    refute err_tuple.message =~ "SENTINEL_9f3a"
  end
end
