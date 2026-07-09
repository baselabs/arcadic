defmodule Arcadic.Error do
  @moduledoc """
  A server-returned ArcadeDB error, normalized to a typed `reason`.

  `detail` (statement-shape text — value-free under the params-only rule) is a
  struct field for debugging, but is QUARANTINED: it appears in neither
  `Exception.message/1` nor `inspect/1` (AGENTS.md Critical Rule 3). Reach it only
  via explicit `error.detail`.

  ## `reason` taxonomy

  Server-derived (mapped from the HTTP status and/or the ArcadeDB `exception` FQN
  in `from_response/2`):

  - `:not_idempotent` — a write reached the read-only `/query` endpoint
    (`QueryNotIdempotentException`).
  - `:parse_error` — the statement failed to parse (`Parsing`/`ParseException`).
  - `:unauthorized` — bad credentials, or an HTTP 403 (`SecurityException`).
  - `:database_not_found` — the target database doesn't exist
    (`DatabaseOperationException`).
  - `:transaction_error` — a transaction-lifecycle failure, both server-derived
    (`TransactionException`) and client-raised (no active/already-open session;
    a Bolt commit failure).
  - `:concurrent_modification` — an optimistic-concurrency conflict
    (`ConcurrentModificationException`/`NeedRetryException`).
  - `:duplicate_key` — a unique-index violation (`DuplicatedKeyException`).
  - `:timeout` — the server reported a timeout (`TimeoutException`).
  - `:invalid_begin_body` — a malformed `isolationLevel` in a transaction-begin body.
  - `:server_error` — the generic fallback: an unrecognized HTTP 400 body, or an
    `exception` FQN that matches none of the above.

  Client-side (raised BY arcadic, never by the server — the statement never left
  the process):

  - `:use_explain` — `query`/`command` (either transport) or `query_stream` (HTTP)
    was called on a statement that already carries an `EXPLAIN`/`PROFILE` prefix,
    which returns a plan rather than rows; call `explain/4`/`profile/4` instead. The
    guard is response-layer: HTTP via `Arcadic.Result.normalize/1`, Bolt via the
    `execute/4` plan-presence check.
  - `:not_supported` — the active transport doesn't implement the called
    capability (e.g. `explain/4` against a transport without it, HTTP streaming
    inside a transaction, Bolt's admin-only calls, async writes without
    `execute_async/3`).
  """

  defexception [:reason, :http_status, :exception, :message, :detail]

  @type t :: %__MODULE__{
          reason: atom(),
          http_status: pos_integer() | nil,
          exception: String.t() | nil,
          message: String.t() | nil,
          detail: String.t() | nil
        }

  # ArcadeDB exception-class substring → typed reason, in precedence order.
  @exception_reasons [
    {"QueryNotIdempotentException", :not_idempotent},
    {"ParsingException", :parse_error},
    {"ParseException", :parse_error},
    {"SecurityException", :unauthorized},
    {"DatabaseOperationException", :database_not_found},
    {"TransactionException", :transaction_error},
    {"ConcurrentModificationException", :concurrent_modification},
    {"NeedRetryException", :concurrent_modification},
    {"DuplicatedKeyException", :duplicate_key},
    {"TimeoutException", :timeout}
  ]

  @doc "Build an `Arcadic.Error` from an HTTP status and a decoded ArcadeDB error body."
  @spec from_response(pos_integer(), map()) :: t()
  def from_response(status, body) when is_integer(status) and is_map(body) do
    %__MODULE__{
      reason: reason_for(status, body),
      http_status: status,
      exception: body["exception"],
      message: body["error"],
      detail: body["detail"]
    }
  end

  # Only the begin-400 body is handled here — it has NO `exception` key. A 400 that
  # DOES carry an `exception` FQN (e.g. QueryNotIdempotentException when /query rejects
  # a write) must fall through to the exception-matching clause, else it is
  # misclassified as :server_error.
  defp reason_for(400, %{"error" => msg} = body)
       when is_binary(msg) and not is_map_key(body, "exception") do
    if msg =~ "isolationLevel", do: :invalid_begin_body, else: :server_error
  end

  defp reason_for(403, _body), do: :unauthorized

  defp reason_for(_status, %{"exception" => fqn}) when is_binary(fqn) do
    # First-match wins — order encodes precedence (was a top-to-bottom `cond`).
    case Enum.find(@exception_reasons, fn {substr, _reason} -> fqn =~ substr end) do
      {_substr, reason} -> reason
      nil -> :server_error
    end
  end

  defp reason_for(_status, _body), do: :server_error

  @impl true
  @spec message(t()) :: String.t()
  # Client-side reasons (:use_explain, :not_supported) are raised BY arcadic, not the server;
  # their :message is a static, developer-authored hint (no statement/params — Rule 3 safe) and
  # is the point of the error, so surface it. Server-origin reasons keep the generic render
  # (their :message holds server "error" text, quarantined from message/1 and inspect/1).
  def message(%__MODULE__{reason: reason, message: msg})
      when reason in [:use_explain, :not_supported] and is_binary(msg),
      do: msg

  def message(%__MODULE__{reason: reason, http_status: status, exception: exception}) do
    "ArcadeDB error (#{inspect(reason)}, HTTP #{status}): #{exception || "unknown"}"
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(err, opts) do
      concat([
        "#Arcadic.Error<",
        to_doc(
          %{reason: err.reason, http_status: err.http_status, exception: err.exception},
          opts
        ),
        ">"
      ])
    end
  end
end
