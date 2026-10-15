defmodule Arcadic.IngestTest do
  @moduledoc """
  Unit coverage for the Ingest facade's always-on contract: total value-free guards, option
  VALUE validation (the Bulk precedent), capability-before-empty short-circuit, and the
  identifier rejection. Live gRPC ingest behavior is covered by the integration suite.
  """
  use ExUnit.Case, async: true
  alias Arcadic.{Conn, Ingest}

  defp http_conn,
    do: Conn.new("http://arcade.invalid", "mydb", auth: {"root", "x"})

  describe "total value-free guards" do
    test "a non-binary target_class raises value-free" do
      err = assert_raise ArgumentError, fn -> Ingest.insert(http_conn(), :Doc, [%{"n" => 1}]) end
      assert Exception.message(err) =~ "target_class must be a string"
    end

    test "non-list rows raise value-free" do
      err = assert_raise ArgumentError, fn -> Ingest.insert(http_conn(), "Doc", %{n: 1}) end
      assert Exception.message(err) =~ "rows must be a list"
    end

    test "unknown option keys are rejected" do
      assert_raise ArgumentError, ~r/unknown option/, fn ->
        Ingest.insert(http_conn(), "Doc", [%{"n" => 1}], chunksize: 5)
      end
    end
  end

  describe "option VALUE validation (a bad value must fail at the facade, value-free)" do
    test "a non-integer chunk_size is rejected (was: deep gRPC crash with encoded rows in blame)" do
      err =
        assert_raise ArgumentError, fn ->
          Ingest.insert(http_conn(), "Doc", [%{"n" => 1}], chunk_size: "500")
        end

      assert Exception.message(err) =~ "chunk_size must be a positive integer"
    end

    test "a zero/negative chunk_size is rejected (was: silent row-at-a-time coercion)" do
      assert_raise ArgumentError, ~r/positive integer/, fn ->
        Ingest.insert(http_conn(), "Doc", [%{"n" => 1}], chunk_size: 0)
      end
    end

    test "a non-integer timeout is rejected" do
      assert_raise ArgumentError, ~r/timeout must be a positive integer/, fn ->
        Ingest.insert(http_conn(), "Doc", [%{"n" => 1}], timeout: :forever)
      end
    end

    test "key_columns must be a list of strings" do
      assert_raise ArgumentError, ~r/key_columns/, fn ->
        Ingest.insert(http_conn(), "Doc", [%{"n" => 1}], key_columns: "name")
      end

      assert_raise ArgumentError, ~r/key_columns/, fn ->
        Ingest.insert(http_conn(), "Doc", [%{"n" => 1}], key_columns: [:name])
      end
    end

    test "an unknown conflict_mode is rejected value-free" do
      assert_raise ArgumentError, ~r/conflict_mode/, fn ->
        Ingest.insert(http_conn(), "Doc", [%{"n" => 1}], conflict_mode: :overwrite)
      end
    end
  end

  describe "capability + identifier contract" do
    test "an HTTP conn gets :not_supported (never UndefinedFunctionError)" do
      assert {:error, %Arcadic.Error{reason: :not_supported}} =
               Ingest.insert(http_conn(), "Doc", [%{"n" => 1}])
    end

    test "capability is checked BEFORE the empty short-circuit (Bulk precedent)" do
      assert {:error, %Arcadic.Error{reason: :not_supported}} =
               Ingest.insert(http_conn(), "Doc", [])
    end

    test "an invalid class identifier yields {:error, :invalid_identifier}" do
      assert {:error, :invalid_identifier} = Ingest.insert(http_conn(), "1bad", [%{"n" => 1}])
    end
  end
end
