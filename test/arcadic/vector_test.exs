defmodule Arcadic.VectorTest do
  use ExUnit.Case, async: true
  alias Arcadic.{Conn, Vector}

  defp conn,
    do:
      Conn.new("http://arcade.invalid", "mydb",
        auth: {"root", "x"},
        transport_options: [plug: {Req.Test, __MODULE__}]
      )

  describe "index_ref/2" do
    test "composes the server-derived ref for valid identifiers" do
      assert {:ok, "Doc[embedding]"} = Vector.index_ref("Doc", "embedding")
    end

    test "rejects a bad type or property value-free (no ref leaked)" do
      assert {:error, :invalid_identifier} = Vector.index_ref("Doc]; DROP", "embedding")
      assert {:error, :invalid_identifier} = Vector.index_ref("Doc", "embedding]; x")
      assert {:error, :invalid_identifier} = Vector.index_ref("Doc", "weird-name?")
    end
  end
end
