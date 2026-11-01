defmodule Arcadic.Integration.ErrorMappingTest do
  @moduledoc """
  LIVE drift guard for the never-created-database error mapping. The unit table
  in `ErrorTest` proves the class→reason rows, but it cannot see upstream RENAME
  the class: 26.11.1-SNAPSHOT answers a missing database 404 with
  `DatabaseNotFoundException` (was `DatabaseNotAvailableException` on 26.10,
  `DatabaseOperationException`/500 on <=26.9), which fell through to
  `:server_error` until mapped (2026-11-01). This test runs the mapping against
  the REAL server so a future rename goes red HERE, with the raw status + class
  (structure only, never values) printed in the failure for the fix.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Arcadic.{Conn, Error}

  setup_all do
    url =
      System.get_env("ARCADIC_TEST_URL") ||
        flunk("set ARCADIC_TEST_URL to a live ArcadeDB base url")

    pass = System.get_env("ARCADIC_TEST_PASSWORD") || flunk("set ARCADIC_TEST_PASSWORD")
    {:ok, url: url, pass: pass}
  end

  test "a never-created database maps to :database_not_found on this server line", %{
    url: url,
    pass: pass
  } do
    missing = "arcadic_missing_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    conn = Conn.new(url, missing, auth: {"root", pass})

    assert {:error, %Error{} = err} = Arcadic.query(conn, "RETURN 1 AS one"),
           "a never-created database must error, not succeed"

    assert err.reason == :database_not_found,
           "drift: this server answers a missing database with " <>
             "HTTP #{inspect(err.http_status)} class #{inspect(err.exception)}" <>
             " — map it to :database_not_found in Arcadic.Error and date it here"
  end
end
