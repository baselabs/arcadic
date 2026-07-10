defmodule Arcadic.ParamTest do
  use ExUnit.Case, async: true
  alias Arcadic.Param

  @secret_val 999

  describe "int8/1" do
    test "wraps a valid signed-byte list as the single-key $int8 marker" do
      assert Param.int8([0, 64, 127, -1, -128]) == %{"$int8" => [0, 64, 127, -1, -128]}
    end

    test "empty list is allowed" do
      assert Param.int8([]) == %{"$int8" => []}
    end

    test "an out-of-range element raises value-free (never echoes the value)" do
      err = assert_raise ArgumentError, fn -> Param.int8([0, @secret_val, 0]) end
      refute err.message =~ "999"
    end

    test "a non-integer element raises value-free" do
      err = assert_raise ArgumentError, fn -> Param.int8([0, 1.5, 0]) end
      refute err.message =~ "1.5"
    end

    test "a non-list raises value-free" do
      err = assert_raise ArgumentError, fn -> Param.int8("SEKRIT") end
      refute err.message =~ "SEKRIT"
    end

    test "128 (one past the upper bound) is rejected" do
      assert_raise ArgumentError, fn -> Param.int8([127, 128]) end
    end

    test "-129 (one past the lower bound) is rejected" do
      assert_raise ArgumentError, fn -> Param.int8([-129, -128]) end
    end
  end

  describe "bytes/1" do
    test "base64-encodes a binary as the single-key $bytes marker" do
      # bytes [0,64,127,255,128] -> base64 "AEB//4A="
      assert Param.bytes(<<0, 64, 127, 255, 128>>) == %{"$bytes" => "AEB//4A="}
    end

    test "a non-binary raises value-free" do
      err = assert_raise ArgumentError, fn -> Param.bytes([1, 2, 3]) end
      refute err.message =~ "[1, 2, 3]"
    end

    test "an empty binary encodes to the empty-string $bytes marker" do
      assert Param.bytes(<<>>) == %{"$bytes" => ""}
    end
  end
end
