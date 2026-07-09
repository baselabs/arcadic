defmodule Arcadic.ErrorTest do
  use ExUnit.Case, async: true
  alias Arcadic.{Error, TransportError}

  describe "from_response/2 reason mapping" do
    test "maps known ArcadeDB exceptions to typed reasons" do
      cases = [
        {"com.arcadedb.exception.QueryNotIdempotentException", 500, :not_idempotent},
        {"com.arcadedb.exception.CommandParsingException", 500, :parse_error},
        {"com.arcadedb.server.security.ServerSecurityException", 403, :unauthorized},
        {"com.arcadedb.exception.DatabaseOperationException", 500, :database_not_found},
        {"com.arcadedb.exception.TransactionException", 500, :transaction_error},
        {"com.arcadedb.exception.ConcurrentModificationException", 500, :concurrent_modification},
        {"com.arcadedb.exception.DuplicatedKeyException", 500, :duplicate_key},
        {"com.arcadedb.exception.TimeoutException", 500, :timeout}
      ]

      for {fqn, status, reason} <- cases do
        body = %{"error" => "x", "detail" => "d", "exception" => fqn}

        assert %Error{reason: ^reason} = Error.from_response(status, body),
               "expected #{reason} for #{fqn}"
      end
    end

    test "maps the begin-400 body to :invalid_begin_body" do
      body = %{"error" => "Missing parameter 'isolationLevel'"}
      assert %Error{reason: :invalid_begin_body} = Error.from_response(400, body)
    end

    test "maps a 400 carrying an exception FQN to the exception reason, not :server_error" do
      body = %{
        "error" => "boom",
        "exception" => "com.arcadedb.exception.QueryNotIdempotentException"
      }

      assert %Error{reason: :not_idempotent} = Error.from_response(400, body)
    end

    test "falls back to :server_error for an unmapped exception" do
      body = %{"error" => "x", "exception" => "com.arcadedb.exception.SomethingNew"}
      assert %Error{reason: :server_error} = Error.from_response(500, body)
    end

    test "captures http_status, exception, message, and detail" do
      body = %{
        "error" => "boom",
        "detail" => "at line 1",
        "exception" => "com.arcadedb.exception.CommandParsingException"
      }

      err = Error.from_response(500, body)
      assert err.http_status == 500
      assert err.exception == "com.arcadedb.exception.CommandParsingException"
      assert err.message == "boom"
      assert err.detail == "at line 1"
    end
  end

  describe "redaction (Critical Rule 3)" do
    setup do
      %{
        err:
          Error.from_response(500, %{
            "error" => "boom",
            "detail" => "SECRET-STATEMENT-SHAPE",
            "exception" => "com.arcadedb.exception.CommandParsingException"
          })
      }
    end

    test "message/1 renders reason/status/exception but NOT detail", %{err: err} do
      msg = Exception.message(err)
      assert msg =~ "parse_error"
      assert msg =~ "500"
      refute msg =~ "SECRET-STATEMENT-SHAPE"
    end

    test "inspect/1 never renders detail", %{err: err} do
      refute inspect(err) =~ "SECRET-STATEMENT-SHAPE"
    end

    test "detail is still reachable by explicit field access", %{err: err} do
      assert err.detail == "SECRET-STATEMENT-SHAPE"
    end
  end

  describe "message/1 client-side surfacing" do
    test "message/1 surfaces the client-side hint for :use_explain and :not_supported" do
      e = %Arcadic.Error{
        reason: :not_supported,
        message: "transport does not support explain/profile"
      }

      assert Exception.message(e) == "transport does not support explain/profile"

      u = %Arcadic.Error{
        reason: :use_explain,
        message: "use Arcadic.explain/3 or Arcadic.profile/3"
      }

      assert Exception.message(u) =~ "explain/3"
    end

    test "message/1 keeps the generic render for a server reason (:message stays quarantined — Rule 3)" do
      e = %Arcadic.Error{
        reason: :parse_error,
        http_status: 400,
        exception: "com.x.ParseException",
        message: "SECRET server text"
      }

      rendered = Exception.message(e)
      assert rendered == "ArcadeDB error (:parse_error, HTTP 400): com.x.ParseException"
      refute rendered =~ "SECRET"
    end
  end

  describe "TransportError" do
    test "carries a network reason atom and renders it" do
      err = %TransportError{reason: :econnrefused}
      assert Exception.message(err) =~ "econnrefused"
      assert inspect(err) =~ "econnrefused"
    end
  end
end
