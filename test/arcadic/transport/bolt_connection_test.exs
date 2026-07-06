if Code.ensure_loaded?(Boltx) do
  defmodule Arcadic.Transport.Bolt.ConnectionTest do
    use ExUnit.Case, async: true
    alias Arcadic.Transport.Bolt.Connection
    alias Arcadic.TransportError

    # A minimal state carrying the cursor flag; the guard reads only :cursor_open?, so a
    # bare map exercises it server-free (mirrors bolt.ex assert_has_more_key!/2 unit style).
    test "handle_execute refuses value-free while a cursor is open (no interleave on the tx socket)" do
      state = %{client: :fake, cursor_open?: true}

      assert {:error, %TransportError{reason: :cursor_open}, ^state} =
               Connection.handle_execute(:q, %{}, [], state)
    end

    test "handle_declare refuses a second concurrent cursor value-free" do
      state = %{client: :fake, cursor_open?: true}

      assert {:error, %TransportError{reason: :cursor_already_open}, ^state} =
               Connection.handle_declare(:q, %{}, [], state)
    end
  end
end
