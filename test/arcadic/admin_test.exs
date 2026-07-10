defmodule Arcadic.AdminTest do
  use ExUnit.Case, async: true
  # Arcadic.Admin is @moduledoc-false internal plumbing shared by Server/Security/Backup; these
  # cover its contract-totality guards directly (no live transport needed).
  alias Arcadic.Admin

  test "span/2 raises value-free on an off-contract thunk return (no value echo — Rule 3)" do
    # An off-contract return (a bare tuple/map/list/nil) would otherwise CaseClauseError, which renders
    # the offending value — a Rule-3 leak if it carries caller data. Must raise value-free instead.
    e =
      assert_raise ArgumentError, fn ->
        Admin.span(:probe, fn -> {:weird, "SENTINEL_VALUE"} end)
      end

    refute Exception.message(e) =~ "SENTINEL_VALUE"
  end

  test "to_ok/1 raises value-free on an off-contract result shape (no value echo — Rule 3)" do
    e = assert_raise ArgumentError, fn -> Admin.to_ok({:weird, "SENTINEL_VALUE"}) end
    refute Exception.message(e) =~ "SENTINEL_VALUE"
  end

  test "span/2 preserves the three contract shapes" do
    assert :ok = Admin.span(:probe, fn -> :ok end)
    assert {:ok, 1} = Admin.span(:probe, fn -> {:ok, 1} end)
    assert {:error, :nope} = Admin.span(:probe, fn -> {:error, :nope} end)
  end
end
