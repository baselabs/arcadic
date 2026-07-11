defmodule Arcadic.Transport.HTTP do
  @moduledoc """
  The HTTP Cypher transport (the only implementation of `Arcadic.Transport`).

  Reads go to `/api/v1/query/<db>` (server-enforced idempotent), writes to
  `/api/v1/command/<db>`. The `arcadedb-session-id` header is echoed on every
  request whenever `conn.session_id` is set, so reads and writes inside a
  transaction are session-scoped. Req's own client retry is disabled — retry
  semantics are the caller's (`retries:` body param) and the error taxonomy's.
  """

  @behaviour Arcadic.Transport

  alias Arcadic.{Conn, Error, Result, Telemetry, TransportError}
  require Logger

  # Writes may have been applied before a post-send close (ambiguous), so a WRITE fails over only
  # on PRE-SEND connect-phase errors; a READ is idempotent → fails over on any connection error.
  # A :not_leader response body is a rejection (nothing applied) → fails over for both modes.
  @presend_reasons [:econnrefused, :nxdomain]

  @impl true
  def execute(%Conn{} = conn, mode, request, opts) when mode in [:read, :write] do
    path = "/api/v1/#{endpoint(mode)}/#{conn.database}"
    body = build_body(request, opts)
    execute_hosts(conn, [conn.base_url | conn.hosts], path, body, opts, mode, 0)
  end

  # Last host: return whatever it yields (no more failover targets).
  defp execute_hosts(conn, [url], path, body, opts, _mode, _idx) do
    %{conn | base_url: url} |> post(path, body, opts) |> handle_result()
  end

  defp execute_hosts(conn, [url | rest], path, body, opts, mode, idx) do
    result = %{conn | base_url: url} |> post(path, body, opts) |> handle_result()

    if failover?(result, mode) do
      # Value-free (D18): log the host INDEX, never the URL (base_url may carry userinfo) or a value.
      Logger.warning("arcadic: host index #{idx} unavailable - failing over to the next host")
      execute_hosts(conn, rest, path, body, opts, mode, idx + 1)
    else
      result
    end
  end

  defp failover?({:error, %TransportError{reason: reason}}, :read) when is_atom(reason), do: true

  defp failover?({:error, %TransportError{reason: reason}}, :write),
    do: reason in @presend_reasons

  # A rejected-by-non-leader write/read is safe to re-send to another host (nothing applied).
  defp failover?({:error, %Error{reason: :not_leader}}, _mode), do: true
  defp failover?(_result, _mode), do: false

  @impl true
  @spec execute_with_index(Conn.t(), :read | :write, Arcadic.Transport.request(), keyword()) ::
          {:ok, [map()], integer() | nil} | {:error, Error.t() | TransportError.t()}
  def execute_with_index(%Conn{} = conn, mode, request, opts) when mode in [:read, :write] do
    path = "/api/v1/#{endpoint(mode)}/#{conn.database}"
    body = build_body(request, opts)

    case post(conn, path, body, opts) do
      {:ok, %Req.Response{} = resp} = ok ->
        case handle_result(ok) do
          {:ok, rows} -> {:ok, rows, commit_index(resp)}
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        handle_result(err)
    end
  end

  # The HA commit-index bookmark rides the X-ArcadeDB-Commit-Index response header; absent on a
  # single (non-HA) server. Parse value-free (Integer.parse, never String.to_integer which would
  # echo a malformed value into a raise — Rule 3).
  defp commit_index(%Req.Response{} = resp) do
    case Req.Response.get_header(resp, "x-arcadedb-commit-index") do
      [raw | _] ->
        case Integer.parse(raw) do
          {n, _} -> n
          :error -> nil
        end

      _ ->
        nil
    end
  end

  @impl true
  @spec explain(Conn.t(), Arcadic.Transport.request(), keyword()) ::
          Arcadic.Transport.plan_result()
  def explain(%Conn{} = conn, request, opts) do
    conn
    |> post("/api/v1/command/#{conn.database}", build_body(request, opts), opts)
    |> handle_plan_result()
  end

  defp endpoint(:read), do: "query"
  defp endpoint(:write), do: "command"

  @paging_clause_re ~r/\b(order\s+by|skip|limit)\b/i
  # SQL comment tokens; a trailing `--` or `/*` would comment OUT arcadic's appended paging suffix so
  # the page runs unpaged (full result, HTTP 200) and `length(rows) < chunk` never trips — a silent,
  # non-terminating stream. Cypher additionally has `//` (line comment) with the same hazard (probed).
  @sql_comment_re ~r/(--|\/\*)/
  @cypher_comment_re ~r/(--|\/\*|\/\/)/

  defp comment_re("cypher"), do: @cypher_comment_re
  defp comment_re(_), do: @sql_comment_re

  # A Cypher :order_key is a caller-supplied ORDER expression interpolated into the paging suffix.
  # It is restricted to EXACTLY `id(<identifier>)` — the only probed TOTAL order over HTTP (a
  # non-unique key like `n.age` would silently dup/lose rows across stateless offset pages, so the
  # allowlist is correctness-tight, not merely injection-tight). Anchored \A…\z (never ^…$ — PCRE $
  # matches before a trailing newline, which would admit `id(n)\n<payload>`).
  @order_key_re ~r/\Aid\([A-Za-z_][A-Za-z0-9_]*\)\z/
  # arcadic OWNS these param names (it binds the offsets); a caller param of the same name would be
  # silently clobbered by Map.merge, mis-binding the caller's own predicate. Reserve BOTH the string
  # and atom forms — Jason stringifies an atom key, so an atom `:__arcadic_skip` would slip a
  # string-only guard and then collide as a DUPLICATE JSON key that ArcadeDB binds last.
  @reserved_params ["__arcadic_skip", "__arcadic_limit", :__arcadic_skip, :__arcadic_limit]

  # The keyset cursor is an arcadic-owned, server-returned @rid LITERAL interpolated into the next
  # page's `WHERE @rid > <cursor>` (param-bound @rid is dead — probed). It is injection-inert ONLY
  # by this positive allowlist: exactly `#<cluster>:<position>`, digits only, anchored \A…\z (never
  # ^…$ — PCRE $ matches before a trailing newline). Any other shape fails the stream LOUD.
  @rid_cursor_re ~r/\A#\d+:\d+\z/

  # @rid is arcadic's RESERVED SQL paging column: the appended `ORDER BY @rid` orders by it and the
  # keyset cursor is READ from it. A caller projection that REBINDS @rid — `… AS `@rid`` (backtick),
  # `… AS @rid` (bare), or the backtick implicit-alias `… `@rid`` (all three accepted by ArcadeDB,
  # probed 2026-07-06) — makes ORDER BY @rid bind to the caller's column, so the real record RID
  # never reaches the row and the cursor becomes caller-controlled: SILENT truncation or a re-serve
  # loop, injection-free (the shadow value still passes @rid_cursor_re). Structurally a shadowed row
  # is indistinguishable from a bare row (both carry @rid, no alias column), so this can only be
  # caught in the STATEMENT text — reject it value-free, the same collision-guard posture as
  # @paging_clause_re / comment_re / @reserved_params. A backtick-quoted `@rid`, or `@rid` right after
  # `AS`, is only ever an alias TARGET; a legitimate bare `SELECT @rid, …` (real-RID projection) has
  # neither, so it streams unaffected. SQL-only — Cypher pages by an offset counter, never an @rid
  # cursor. Best-effort like the sibling textual guards (an exotic alias syntax is a documented
  # residual; @rid is reserved — see the query_stream/4 @doc).
  @rid_alias_re ~r/(?:`|\bas\s+`?)@rid/i

  @impl true
  @spec query_stream(Conn.t(), Arcadic.Transport.request(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def query_stream(%Conn{session_id: sid}, _request, _opts) when is_binary(sid) do
    {:error,
     %Error{
       reason: :not_supported,
       message: "HTTP streaming is not available inside a transaction"
     }}
  end

  def query_stream(
        %Conn{} = conn,
        %{statement: statement, params: params, language: language},
        opts
      ) do
    with :ok <- check_streamable(statement, params, language) do
      if language == "cypher",
        do: stream_cypher(conn, statement, params, opts),
        else: {:ok, build_sql_stream(conn, statement, params, opts)}
    end
  end

  # Every value-free streamability rejection in one place (`:ok` or `{:error, Error.t()}`) so
  # query_stream/3 stays flat: an unsupported language; a caller ORDER BY/SKIP/LIMIT that would
  # collide with arcadic's suffix; a comment (--, /*, or // for cypher) that would neutralize it; a
  # caller param colliding with the reserved paging namespace; and (SQL) a projection that rebinds
  # arcadic's reserved @rid paging column (see @rid_alias_re). None echoes the statement/value (Rule 3).
  defp check_streamable(statement, params, language) do
    cond do
      language not in ["sql", "cypher"] ->
        {:error,
         %Error{
           reason: :not_supported,
           message: "HTTP streaming requires language: \"sql\" or \"cypher\""
         }}

      Regex.match?(@paging_clause_re, statement) ->
        {:error,
         %Error{
           reason: :not_supported,
           message:
             "HTTP streaming statement must not contain ORDER BY / SKIP / LIMIT (arcadic pages it)"
         }}

      Regex.match?(comment_re(language), statement) ->
        {:error,
         %Error{
           reason: :not_supported,
           message:
             "HTTP streaming statement must not contain a comment (--, /*, or // for cypher) — it would neutralize arcadic's paging suffix"
         }}

      Enum.any?(@reserved_params, &Map.has_key?(params, &1)) ->
        {:error,
         %Error{
           reason: :not_supported,
           message:
             "HTTP streaming reserves the params __arcadic_skip / __arcadic_limit (arcadic pages the statement)"
         }}

      language == "sql" and Regex.match?(@rid_alias_re, statement) ->
        {:error,
         %Error{
           reason: :not_supported,
           message:
             "HTTP SQL streaming reserves @rid as its paging column — the statement must not alias an output column to @rid"
         }}

      true ->
        :ok
    end
  end

  # SQL streaming: WHERE-less pages by the O(n) @rid keyset, a caller WHERE falls back to O(n²) offset.
  defp build_sql_stream(conn, statement, params, opts) do
    chunk = Keyword.get(opts, :chunk_size, 1000)
    timeout = Keyword.get(opts, :timeout, :infinity)

    if has_where?(statement),
      do: build_offset_stream(conn, statement, params, chunk, timeout),
      else: build_keyset_stream(conn, statement, params, chunk, timeout)
  end

  # Cypher streaming: validate the required :order_key, then OFFSET-page over it with Cypher $name
  # placeholders (Cypher has no variable-free order pseudo-column to append, and a keyset predicate
  # would need a mid-statement WHERE = no-parse-blocked → offset only). Documents are
  # Cypher-unmatchable (ClassCastException, probed) → they stay on the SQL path.
  defp stream_cypher(conn, statement, params, opts) do
    case Keyword.get(opts, :order_key) do
      key when is_binary(key) ->
        if Regex.match?(@order_key_re, key) do
          chunk = Keyword.get(opts, :chunk_size, 1000)
          timeout = Keyword.get(opts, :timeout, :infinity)
          {:ok, build_cypher_offset_stream(conn, statement, key, params, chunk, timeout)}
        else
          {:error,
           %Error{
             reason: :not_supported,
             message: "cypher :order_key must be exactly id(<identifier>) (a total, unique order)"
           }}
        end

      _ ->
        {:error,
         %Error{
           reason: :not_supported,
           message: "cypher HTTP streaming requires :order_key (e.g. order_key: \"id(v)\")"
         }}
    end
  end

  # The shared paging skeleton for all three HTTP stream modes (SQL keyset, SQL offset, Cypher
  # offset): value-free `[:arcadic, :query_stream, :start|:stop]` telemetry (spec §6) around a
  # per-page `step` fun. `start` fires on the first page; the after-fun runs on drain, early halt,
  # AND a mid-stream raise, so `:stop` always fires (`reason`: `:ok` drained, `:halted` stopped
  # early). Mirrors the Bolt stream path (bolt.ex stream_start/stream_stop). Every acc carries
  # `rows` + `done` (the mode-specific `offset`/`cursor` rides alongside); `step` is only ever
  # called with a NOT-done acc and returns a `Stream.resource` reduce result.
  defp page_stream(init_acc, step) do
    Stream.resource(
      fn ->
        Telemetry.event([:arcadic, :query_stream, :start], %{}, %{mode: :read})
        init_acc
      end,
      fn
        %{done: true} = acc -> {:halt, acc}
        acc -> step.(acc)
      end,
      fn acc ->
        reason = if acc.done, do: :ok, else: :halted

        Telemetry.event([:arcadic, :query_stream, :stop], %{row_count: acc.rows}, %{
          mode: :read,
          reason: reason
        })
      end
    )
  end

  # Offset paging (WHERE-present SQL, and Cypher): append arcadic's OWN fixed suffix; offsets ride
  # params. Stable ordering within a snapshot, but each page is an independent stateless POST — a
  # concurrent DELETE of an already-emitted row shifts later rows down and the next SKIP can step
  # over one. Use a Bolt in-tx cursor for snapshot consistency. ArcadeDB SQL binds `:name`
  # placeholders, NOT `$name` (Cypher's syntax); a `$`-named SQL param binds to null → `Invalid
  # value for LIMIT: null`.
  defp build_offset_stream(conn, statement, params, chunk, timeout) do
    paged = statement <> " ORDER BY @rid SKIP :__arcadic_skip LIMIT :__arcadic_limit"

    page_stream(%{offset: 0, rows: 0, done: false}, fn %{offset: offset} = acc ->
      page_params = Map.merge(params, %{"__arcadic_skip" => offset, "__arcadic_limit" => chunk})
      emit_page(page(conn, paged, page_params, timeout, "sql"), chunk, acc)
    end)
  end

  # Cypher offset paging: same machinery as build_offset_stream but with a Cypher suffix ($name
  # placeholders + the validated order_key) and language "cypher" on the page body.
  defp build_cypher_offset_stream(conn, statement, order_key, params, chunk, timeout) do
    paged = statement <> " ORDER BY #{order_key} SKIP $__arcadic_skip LIMIT $__arcadic_limit"

    page_stream(%{offset: 0, rows: 0, done: false}, fn %{offset: offset} = acc ->
      page_params = Map.merge(params, %{"__arcadic_skip" => offset, "__arcadic_limit" => chunk})
      emit_page(page(conn, paged, page_params, timeout, "cypher"), chunk, acc)
    end)
  end

  # Keyset paging (O(n)) for WHERE-less SQL: page 1 has no WHERE; each later page adds a trailing
  # `WHERE @rid > <cursor-literal>` where <cursor> is the MAX @rid of the previous page (rows come
  # back @rid-ascending). Free of the offset-shift skip a concurrent delete causes, and O(n) instead
  # of O(n²) (no re-scan). The cursor is arcadic-owned + allowlist-validated.
  defp build_keyset_stream(conn, statement, params, chunk, timeout) do
    page_stream(%{cursor: nil, rows: 0, done: false}, fn %{cursor: cursor} = acc ->
      paged = keyset_page_statement(statement, cursor)
      page_params = Map.merge(params, %{"__arcadic_limit" => chunk})
      emit_keyset_page(page(conn, paged, page_params, timeout, "sql"), chunk, acc)
    end)
  end

  # Page 1 (cursor nil): the bare statement + ORDER BY @rid LIMIT. Page N: a trailing keyset predicate.
  defp keyset_page_statement(statement, nil),
    do: statement <> " ORDER BY @rid LIMIT :__arcadic_limit"

  defp keyset_page_statement(statement, cursor),
    do: statement <> " WHERE @rid > #{cursor} ORDER BY @rid LIMIT :__arcadic_limit"

  # A full page (== chunk) advances the offset; a short/empty page is the last (drain).
  defp emit_page({:ok, []}, _chunk, acc), do: {:halt, %{acc | done: true}}

  defp emit_page({:ok, rows}, chunk, acc) do
    shaped = Enum.map(rows, &strip_order_alias/1)
    acc = %{acc | rows: acc.rows + length(rows), offset: acc.offset + chunk}
    next = if length(rows) < chunk, do: %{acc | done: true}, else: acc
    {shaped, next}
  end

  defp emit_page({:error, e}, _chunk, _acc), do: raise(e)

  # A full page (== chunk) advances the cursor to the page's MAX @rid; a short/empty page drains.
  defp emit_keyset_page({:ok, []}, _chunk, acc), do: {:halt, %{acc | done: true}}

  defp emit_keyset_page({:ok, rows}, chunk, acc) do
    cursor = extract_rid_cursor!(List.last(rows))
    shaped = Enum.map(rows, &strip_order_alias/1)
    acc = %{acc | rows: acc.rows + length(rows), cursor: cursor}
    next = if length(rows) < chunk, do: %{acc | done: true}, else: acc
    {shaped, next}
  end

  defp emit_keyset_page({:error, e}, _chunk, _acc), do: raise(e)

  # The cursor is read from the row's `@rid` key (bare SELECT) or the `_$$$ORDER_BY_ALIAS$$$_0`
  # column (projection) — both probed. Validate against the allowlist BEFORE it is interpolated; a
  # missing/malformed cursor is protocol drift → raise a value-free error (never silently continue,
  # which could skip or duplicate rows). No caller statement/value is echoed (Rule 3).
  defp extract_rid_cursor!(row) do
    raw = row["@rid"] || row["_$$$ORDER_BY_ALIAS$$$_0"]

    if is_binary(raw) and Regex.match?(@rid_cursor_re, raw) do
      raw
    else
      raise %Error{
        reason: :server_error,
        message: "HTTP keyset stream: page row carried no parseable @rid cursor"
      }
    end
  end

  # `\bwhere\b` (case-insensitive, word-bounded) — a false positive routes to the correct O(n²)
  # offset path (never wrong data); a real SQL WHERE is always tokenized so there is no false
  # negative (which would append a SECOND WHERE and parse-error, a LOUD failure, not silent-wrong).
  defp has_where?(statement), do: Regex.match?(~r/\bwhere\b/i, statement)

  # The body-level `limit` mirrors the statement's `LIMIT :__arcadic_limit` (== chunk). Without it,
  # ArcadeDB's DEFAULT body limit (20000) caps a page BELOW the statement LIMIT, and since a page
  # shorter than `chunk` is treated as the last, a `chunk_size` above the server default would
  # SILENTLY truncate the stream. Setting it to the chunk makes the statement LIMIT the only cap.
  defp page(conn, statement, params, timeout, language) do
    body = %{
      language: language,
      command: statement,
      params: params,
      limit: params["__arcadic_limit"]
    }

    conn
    |> post("/api/v1/query/#{conn.database}", body, timeout: timeout)
    |> handle_result()
  end

  # Appending `ORDER BY @rid` to a PROJECTION makes ArcadeDB inject a synthetic
  # `_$$$ORDER_BY_ALIAS$$$_N` ordering column (probed live) — drop it. `@props` is already
  # dropped by Result.normalize inside handle_result.
  defp strip_order_alias(row) when is_map(row) do
    :maps.filter(fn k, _ -> not String.starts_with?(k, "_$$$ORDER_BY_ALIAS$$$_") end, row)
  end

  defp strip_order_alias(row), do: row

  @impl true
  def begin(%Conn{} = conn, opts) do
    body = isolation_body(opts[:isolation])

    case post(conn, "/api/v1/begin/#{conn.database}", body, opts) do
      {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
        case session_id(resp) do
          nil ->
            {:error,
             %Error{reason: :server_error, http_status: status, message: "no session id returned"}}

          id ->
            {:ok, id}
        end

      other ->
        handle_status_only(other)
    end
  end

  @impl true
  def commit(%Conn{} = conn),
    do: handle_status_only(post(conn, "/api/v1/commit/#{conn.database}", nil))

  @impl true
  def rollback(%Conn{} = conn),
    do: handle_status_only(post(conn, "/api/v1/rollback/#{conn.database}", nil))

  # nil isolation → NO body (the verified default); explicit → isolationLevel body.
  defp isolation_body(nil), do: nil
  defp isolation_body(:read_committed), do: %{isolationLevel: "READ_COMMITTED"}
  defp isolation_body(:repeatable_read), do: %{isolationLevel: "REPEATABLE_READ"}

  defp isolation_body(other),
    do:
      raise(
        ArgumentError,
        "unknown isolation #{inspect(other)}; allowed: [:read_committed, :repeatable_read]"
      )

  defp session_id(%Req.Response{headers: headers}) do
    case headers["arcadedb-session-id"] do
      [id | _] -> id
      _ -> nil
    end
  end

  defp handle_status_only({:ok, %Req.Response{status: status}}) when status in 200..299, do: :ok

  defp handle_status_only({:ok, %Req.Response{status: status, body: body}}) when is_map(body),
    do: {:error, Error.from_response(status, body)}

  defp handle_status_only({:ok, %Req.Response{status: status}}),
    do: {:error, Error.from_response(status, %{"error" => "HTTP #{status}"})}

  defp handle_status_only({:error, %{reason: reason}}),
    do: {:error, %TransportError{reason: reason}}

  defp handle_status_only({:error, _}), do: {:error, %TransportError{reason: :unknown}}

  @doc false
  @spec build_body(Arcadic.Transport.request(), keyword()) :: map()
  def build_body(%{statement: statement, params: params, language: language}, opts) do
    %{language: language, command: statement}
    |> put_if(map_size(params) > 0, :params, params)
    |> put_if(opts[:limit], :limit, opts[:limit])
    |> put_if(opts[:serializer], :serializer, opts[:serializer])
    |> put_if(opts[:retries], :retries, opts[:retries])
    |> put_if(not is_nil(opts[:auto_commit]), :autoCommit, opts[:auto_commit])
  end

  defp put_if(map, condition, key, value),
    do: if(condition, do: Map.put(map, key, value), else: map)

  # Shared POST used by execute/begin/commit/rollback/server ops.
  @doc false
  @spec post(Conn.t(), String.t(), map() | nil, keyword()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  def post(%Conn{} = conn, path, body, opts \\ []) do
    req_opts =
      [
        url: conn.base_url <> path,
        headers: headers(conn),
        retry: false,
        finch: conn.transport_options[:finch],
        plug: conn.transport_options[:plug],
        receive_timeout: opts[:timeout] || conn.timeout
      ]
      |> maybe_put_json(body)
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    Req.post(req_opts)
  end

  # req_opts is a keyword list — use Keyword.put, NOT put_if (which does Map.put → BadMapError).
  defp maybe_put_json(opts, nil), do: opts
  defp maybe_put_json(opts, body), do: Keyword.put(opts, :json, body)

  @doc false
  @spec headers(Conn.t()) :: [{String.t(), String.t()}]
  def headers(%Conn{} = conn) do
    conn
    |> auth_headers()
    |> maybe_session(conn.session_id)
    |> maybe_consistency(conn)
  end

  defp auth_headers(%Conn{auth: {:bearer, token}}), do: [{"authorization", "Bearer " <> token}]

  defp auth_headers(%Conn{auth: {user, pass}}),
    do: [{"authorization", "Basic " <> Base.encode64("#{user}:#{pass}")}]

  defp maybe_session(headers, nil), do: headers
  defp maybe_session(headers, sid), do: [{"arcadedb-session-id", sid} | headers]

  # :eventual sends NO header (ArcadeDB's ReadConsistency.EVENTUAL == "no headers"), so a
  # default conn is byte-identical to pre-S10. read_your_writes also sends X-ArcadeDB-Read-After
  # when a bookmark is present (nil on single-server → omitted). Applied to BOTH auth clauses.
  defp maybe_consistency(headers, %Conn{consistency: :eventual}), do: headers

  defp maybe_consistency(headers, %Conn{consistency: level} = conn) do
    headers = [{"x-arcadedb-read-consistency", Atom.to_string(level)} | headers]
    maybe_read_after(headers, conn)
  end

  defp maybe_read_after(headers, %Conn{consistency: :read_your_writes, read_after: idx})
       when is_integer(idx),
       do: [{"x-arcadedb-read-after", Integer.to_string(idx)} | headers]

  defp maybe_read_after(headers, _conn), do: headers

  # Result handling for a query/command response.
  defp handle_result({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299 and is_map(body) do
    Result.normalize(body)
  end

  # A 2xx whose body is empty/non-map (Req leaves an empty body as "") is a
  # no-result success — degrade to an empty row list, never a FunctionClauseError.
  defp handle_result({:ok, %Req.Response{status: status}}) when status in 200..299 do
    {:ok, []}
  end

  defp handle_result({:ok, %Req.Response{status: status, body: body}}) when is_map(body) do
    {:error, Error.from_response(status, body)}
  end

  defp handle_result({:ok, %Req.Response{status: status}}) do
    {:error, Error.from_response(status, %{"error" => "HTTP #{status}"})}
  end

  defp handle_result({:error, %{reason: reason}}), do: {:error, %TransportError{reason: reason}}

  defp handle_result({:error, exception}),
    do: {:error, %TransportError{reason: inspect_reason(exception)}}

  # Exceptions are always structs (Req returns `{:error, Exception.t()}`), so this
  # single clause is exhaustive per the type — a `_` catch-all would be dead code
  # (dialyzer `pattern_match_cov`).
  defp inspect_reason(%{__struct__: mod}), do: mod

  # Like handle_result/1 but the 2xx-map branch extracts the PLAN (normalize_plan, not normalize —
  # normalize/1's :use_explain clause would fire on explain's own explainPlan envelope and wrongly
  # return {:error, :use_explain}), and the 2xx-empty branch returns the empty plan MAP so the
  # success type stays inside plan_result() (a real EXPLAIN always returns a map body; the empty
  # branch is defensive). Kept SEPARATE from the monomorphic handle_result/1 so execute/4's
  # list-shaped result() contract is not polluted by normalize_plan's map (dialyzer).
  defp handle_plan_result({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299 and is_map(body),
       do: Result.normalize_plan(body)

  defp handle_plan_result({:ok, %Req.Response{status: status}}) when status in 200..299,
    do: {:ok, %{plan: "", plan_tree: %{}, rows: []}}

  defp handle_plan_result({:ok, %Req.Response{status: status, body: body}}) when is_map(body),
    do: {:error, Error.from_response(status, body)}

  defp handle_plan_result({:ok, %Req.Response{status: status}}),
    do: {:error, Error.from_response(status, %{"error" => "HTTP #{status}"})}

  defp handle_plan_result({:error, %{reason: reason}}),
    do: {:error, %TransportError{reason: reason}}

  defp handle_plan_result({:error, exception}),
    do: {:error, %TransportError{reason: inspect_reason(exception)}}

  @impl true
  def server_command(%Conn{} = conn, command) do
    conn |> post("/api/v1/server", %{command: command}, []) |> unwrap_body()
  end

  @impl true
  def batch_ingest(%Conn{} = conn, ndjson, opts) do
    query = batch_query(opts)
    url = conn.base_url <> "/api/v1/batch/#{conn.database}" <> query

    req_opts =
      [
        url: url,
        headers: [{"content-type", "application/x-ndjson"} | headers(conn)],
        body: ndjson,
        retry: false,
        finch: conn.transport_options[:finch],
        plug: conn.transport_options[:plug],
        receive_timeout: opts[:timeout] || conn.timeout
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    req_opts |> Req.post() |> unwrap_body()
  end

  # Only the provided knobs ride the query string, as ArcadeDB's camelCase param names. Edge
  # endpoints resolve by the vertex `@id` temp key in the NDJSON body (or a real RID), never a
  # query param — the endpoint has no `idProperty` support (live-probed 26.8.1-SNAPSHOT).
  defp batch_query(opts) do
    pairs =
      [
        {"lightEdges", opts[:light_edges]},
        {"commitEvery", opts[:commit_every]}
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.map(fn {k, v} -> {k, to_string(v)} end)

    case pairs do
      [] -> ""
      list -> "?" <> URI.encode_query(list)
    end
  end

  # Inlines a map-guarded success branch (NOT the shared unwrap_body/1, whose 2xx clause returns
  # {:ok, term()}) so the success type stays the monomorphic {:ok, map()} the @callback declares.
  @impl true
  def server_get(%Conn{} = conn, path) do
    case raw_get(conn, path) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} when is_map(body) ->
        {:error, Error.from_response(status, body)}

      {:ok, %Req.Response{status: status}} ->
        {:error, Error.from_response(status, %{"error" => "HTTP #{status}"})}

      {:error, %{reason: reason}} ->
        {:error, %TransportError{reason: reason}}

      {:error, _} ->
        {:error, %TransportError{reason: :unknown}}
    end
  end

  @impl true
  def health?(%Conn{} = conn) do
    case raw_get(conn, "/api/v1/health") do
      {:ok, %Req.Response{status: 204}} -> {:ok, true}
      {:ok, %Req.Response{}} -> {:ok, false}
      {:error, %{reason: reason}} -> {:error, %TransportError{reason: reason}}
      {:error, _} -> {:error, %TransportError{reason: :unknown}}
    end
  end

  @impl true
  def login(%Conn{} = conn) do
    case post(conn, "/api/v1/login", nil, []) do
      {:ok, %Req.Response{status: status, body: %{"token" => token}}}
      when status in 200..299 and is_binary(token) ->
        {:ok, token}

      {:ok, %Req.Response{status: status, body: body}} when is_map(body) ->
        {:error, Error.from_response(status, body)}

      {:ok, %Req.Response{status: status}} ->
        {:error, Error.from_response(status, %{"error" => "HTTP #{status}"})}

      {:error, %{reason: reason}} ->
        {:error, %TransportError{reason: reason}}

      {:error, _} ->
        {:error, %TransportError{reason: :unknown}}
    end
  end

  @impl true
  def logout(%Conn{} = conn), do: handle_status_only(post(conn, "/api/v1/logout", nil))

  @impl true
  def list_databases(%Conn{} = conn) do
    case get(conn, "/api/v1/databases") do
      {:ok, %{"result" => names}} when is_list(names) -> {:ok, names}
      {:ok, _} -> {:ok, []}
      {:error, error} -> {:error, error}
    end
  end

  @impl true
  def database_exists?(%Conn{} = conn, name) do
    with {:ok, names} <- list_databases(conn), do: {:ok, name in names}
  end

  @impl true
  def execute_async(%Conn{} = conn, request, opts) do
    body = request |> build_body(opts) |> Map.put(:awaitResponse, false)

    case post(conn, "/api/v1/#{endpoint(:write)}/#{conn.database}", body, opts) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status, body: b}} when is_map(b) ->
        {:error, Error.from_response(status, b)}

      {:ok, %Req.Response{status: status}} ->
        {:error, Error.from_response(status, %{"error" => "HTTP #{status}"})}

      {:error, %{reason: reason}} ->
        {:error, %TransportError{reason: reason}}

      {:error, _} ->
        {:error, %TransportError{reason: :unknown}}
    end
  end

  @impl true
  def ready?(%Conn{} = conn) do
    case raw_get(conn, "/api/v1/ready") do
      {:ok, %Req.Response{status: 204}} -> {:ok, true}
      {:ok, %Req.Response{}} -> {:ok, false}
      {:error, %{reason: reason}} -> {:error, %TransportError{reason: reason}}
      {:error, _} -> {:error, %TransportError{reason: :unknown}}
    end
  end

  # GET returning a decoded body map (for /databases).
  defp get(%Conn{} = conn, path), do: conn |> raw_get(path) |> unwrap_body()

  defp raw_get(%Conn{} = conn, path) do
    [
      url: conn.base_url <> path,
      headers: headers(conn),
      retry: false,
      finch: conn.transport_options[:finch],
      plug: conn.transport_options[:plug],
      receive_timeout: conn.timeout
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Req.get()
  end

  defp unwrap_body({:ok, %Req.Response{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  defp unwrap_body({:ok, %Req.Response{status: status, body: body}}) when is_map(body),
    do: {:error, Error.from_response(status, body)}

  defp unwrap_body({:ok, %Req.Response{status: status}}),
    do: {:error, Error.from_response(status, %{"error" => "HTTP #{status}"})}

  defp unwrap_body({:error, %{reason: reason}}), do: {:error, %TransportError{reason: reason}}
  defp unwrap_body({:error, _}), do: {:error, %TransportError{reason: :unknown}}
end
