defmodule Arcadic.TimeSeries do
  @moduledoc """
  ArcadeDB time-series — tenant-blind client for the `/api/v1/ts/<db>` wire family (InfluxDB
  line-protocol write, JSON query/latest, PromQL reads) plus the `TIMESERIES` DDL, downsampling
  policies, and continuous aggregates. Requires ArcadeDB >= 26.7.2 (older servers answer the
  `/ts` routes with a plain 404 `%Arcadic.Error{http_status: 404}`).

  DDL and continuous-aggregate statements ride `Arcadic.command/4` (`language: "sql"` — SQL-only
  over Bolt, like `Arcadic.Schema`). The wire family rides optional transport callbacks
  implemented by the HTTP transport only; on any other transport those functions return
  `{:error, %Arcadic.Error{reason: :not_supported}}`.

  Identifiers (type/column/tag/field names) are `Arcadic.Identifier`-validated; grammar tokens
  (column types, duration units, precisions, aggregation functions) are positive-allowlisted.
  The two rejection channels differ: an invalid identifier returns `{:error, :invalid_identifier}`,
  while an invalid opt value (column-type token, duration, precision, shard count) raises a
  value-free `ArgumentError`. Point values are DATA (line protocol / JSON / URL params), never
  statement text.

  ## Operational contract — write path (each clause live-probed on 26.7.2)

  - **Append-only, non-idempotent.** No dedup, no upsert, no server-assigned id: the identical
    point written twice is TWO rows. A lost response followed by a naive retry **duplicates every
    point in the body** (the same non-confirmability class as `Arcadic.Bulk.ingest/3`).
  - **Mixed-body partial swallow.** When at least one line's type exists, lines naming an UNKNOWN
    type are **silently dropped** (HTTP 204). The loud 400 `Unknown timeseries type(s)` fires only
    when every line's type is unknown. `write/3` guarantees syntactic validity by construction,
    but cannot know server type existence (tenant-blind, no schema cache) — a typo'd `type:` in a
    mixed batch is silent. Verify with `query/3` or `Arcadic.Schema.types/1` when it matters.
  - **Unknown FIELD zero-fill.** A line whose field name is not on the type inserts a
    **zero-filled row** (204, no error).
  - **int64 bound.** An integer field value or timestamp outside signed int64
    (±9223372036854775807/8) is a 204 + **silent line drop** server-side (probed both signs) —
    `write/3` raises value-free client-side instead, including on a `DateTime` whose converted
    value overflows. This bound is part of the "syntactic validity by construction" guarantee.
  - **Unknown tag KEY fails open** on `query/3`/`latest/3` (the filter is ignored server-side).
  - `write_lines/3` (raw passthrough) additionally inherits the malformed-line silent-skip.
  """

  alias Arcadic.{Conn, Error, Identifier, Opts, Telemetry}

  @typedoc "A duration for `:retention` / `:compaction_interval` / downsampling opts."
  @type duration :: {pos_integer(), :seconds | :minutes | :hours | :days}

  # Column-type tokens accepted by CREATE TIMESERIES TYPE on 26.7.2 — every token live-probed
  # (spec S1 + plan-write probe). Positive allowlist: the token is interpolated into DDL.
  @column_types ~w(STRING INTEGER LONG DOUBLE BOOLEAN DATETIME FLOAT SHORT BYTE DECIMAL DATE BINARY LIST MAP EMBEDDED)
  # Plural-only in the CREATE clauses (singular parse-errors — probed); safe for downsampling
  # GRANULARITY too (its grammar accepts both).
  @duration_units %{seconds: "SECONDS", minutes: "MINUTES", hours: "HOURS", days: "DAYS"}
  @ddl_precisions %{
    second: "SECOND",
    millisecond: "MILLISECOND",
    microsecond: "MICROSECOND",
    nanosecond: "NANOSECOND"
  }

  @create_type_opts [:fields, :tags, :precision, :shards, :retention, :compaction_interval]
  @downsampling_opts [:after, :granularity]

  @doc """
  Creates a TIMESERIES type: `CREATE TIMESERIES TYPE name TIMESTAMP timestamp_col …`.

  ## Options
    * `:fields` — REQUIRED non-empty `[{name, type}]` (keyword or `{binary, binary}` pairs).
    * `:tags` — `[{name, type}]`, default none (a tagless type is valid — probed).
    * `:precision` — `:second | :millisecond | :microsecond | :nanosecond` (omit → server default
      NANOSECOND).
    * `:shards` — pos_integer.
    * `:retention` / `:compaction_interval` — `t:duration/0`.

  Clause order is the grammar's FIXED order (SHARDS → RETENTION → COMPACTION_INTERVAL); units
  emit as plural tokens. There is no `IF NOT EXISTS` (absent from the 26.7.2 grammar) — creating
  an existing type is a server error. Value-free on any invalid name/token/option.
  """
  @spec create_type(Conn.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, atom() | Exception.t()}
  def create_type(%Conn{} = conn, name, timestamp_col, opts \\ []) do
    Opts.validate_keys!(opts, @create_type_opts)
    fields = columns!(Keyword.get(opts, :fields, []), "at least one field is required")
    tags = optional_columns!(Keyword.get(opts, :tags, []))

    with {:ok, [name_ok, ts_ok]} <- validate_idents([name, timestamp_col]),
         {:ok, tag_cols} <- column_clauses(tags),
         {:ok, field_cols} <- column_clauses(fields) do
      statement =
        "CREATE TIMESERIES TYPE #{name_ok} TIMESTAMP #{ts_ok}" <>
          precision_clause(opts[:precision]) <>
          tags_clause(tag_cols) <>
          " FIELDS (#{Enum.join(field_cols, ", ")})" <>
          shards_clause(opts[:shards]) <>
          duration_clause("RETENTION", opts[:retention]) <>
          duration_clause("COMPACTION_INTERVAL", opts[:compaction_interval])

      command_ok(conn, statement)
    end
  end

  @doc "Creates a TIMESERIES type, raising on error."
  @spec create_type!(Conn.t(), String.t(), String.t(), keyword()) :: :ok
  def create_type!(%Conn{} = conn, name, timestamp_col, opts \\ []),
    do: bang(create_type(conn, name, timestamp_col, opts))

  @doc """
  Drops a TIMESERIES type (`DROP TIMESERIES TYPE name` — no `IF EXISTS`; dropping a missing type
  is a server error, mirroring `Arcadic.Trigger`/`Arcadic.MaterializedView`).
  """
  @spec drop_type(Conn.t(), String.t()) :: :ok | {:error, atom() | Exception.t()}
  def drop_type(%Conn{} = conn, name) do
    with {:ok, [name_ok]} <- validate_idents([name]) do
      command_ok(conn, "DROP TIMESERIES TYPE #{name_ok}")
    end
  end

  @doc "Drops a TIMESERIES type, raising on error."
  @spec drop_type!(Conn.t(), String.t()) :: :ok
  def drop_type!(%Conn{} = conn, name), do: bang(drop_type(conn, name))

  @doc """
  Adds a downsampling policy: `ALTER TIMESERIES TYPE type ADD DOWNSAMPLING POLICY AFTER n UNIT
  GRANULARITY n UNIT`. Both `:after` and `:granularity` are REQUIRED `t:duration/0`s.
  """
  @spec add_downsampling(Conn.t(), String.t(), keyword()) ::
          :ok | {:error, atom() | Exception.t()}
  def add_downsampling(%Conn{} = conn, type, opts) do
    Opts.validate_keys!(opts, @downsampling_opts)
    after_sql = required_duration!(opts, :after)
    gran_sql = required_duration!(opts, :granularity)

    with {:ok, [type_ok]} <- validate_idents([type]) do
      command_ok(
        conn,
        "ALTER TIMESERIES TYPE #{type_ok} ADD DOWNSAMPLING POLICY " <>
          "AFTER #{after_sql} GRANULARITY #{gran_sql}"
      )
    end
  end

  @doc "Adds a downsampling policy, raising on error."
  @spec add_downsampling!(Conn.t(), String.t(), keyword()) :: :ok
  def add_downsampling!(%Conn{} = conn, type, opts), do: bang(add_downsampling(conn, type, opts))

  @doc "Drops the type's downsampling policy (`ALTER TIMESERIES TYPE type DROP DOWNSAMPLING POLICY`)."
  @spec drop_downsampling(Conn.t(), String.t()) :: :ok | {:error, atom() | Exception.t()}
  def drop_downsampling(%Conn{} = conn, type) do
    with {:ok, [type_ok]} <- validate_idents([type]) do
      command_ok(conn, "ALTER TIMESERIES TYPE #{type_ok} DROP DOWNSAMPLING POLICY")
    end
  end

  @doc "Drops the type's downsampling policy, raising on error."
  @spec drop_downsampling!(Conn.t(), String.t()) :: :ok
  def drop_downsampling!(%Conn{} = conn, type), do: bang(drop_downsampling(conn, type))

  @doc """
  Creates a continuous aggregate: `CREATE CONTINUOUS AGGREGATE name AS select_sql`. The SELECT
  rides through VERBATIM — the same injection rationale as `Arcadic.MaterializedView`: it is raw
  trailing SQL (not a quoted literal), and ArcadeDB's live-verified single-statement backstop
  makes a `;`-separated second statement a parse error. The result materializes as a document
  type readable via `SELECT FROM name`. Refresh with `refresh_aggregate/2`.
  """
  @spec create_aggregate(Conn.t(), String.t(), String.t()) ::
          :ok | {:error, atom() | Exception.t()}
  def create_aggregate(%Conn{} = conn, name, select_sql) when is_binary(select_sql) do
    with {:ok, [name_ok]} <- validate_idents([name]) do
      command_ok(conn, "CREATE CONTINUOUS AGGREGATE #{name_ok} AS #{select_sql}")
    end
  end

  # A non-binary select must not FunctionClauseError (blame echoes the args — Rule 3).
  # Fully open fallback (no %Conn{} match), mirroring Arcadic.MaterializedView.create/3:
  # a restrictive head with no total fallback IS the FunctionClauseError leak.
  def create_aggregate(_conn, _name, _select_sql),
    do: raise(ArgumentError, "select must be a string")

  @doc "Creates a continuous aggregate, raising on error."
  @spec create_aggregate!(Conn.t(), String.t(), String.t()) :: :ok
  def create_aggregate!(%Conn{} = conn, name, select_sql),
    do: bang(create_aggregate(conn, name, select_sql))

  @doc "Refreshes a continuous aggregate (`REFRESH CONTINUOUS AGGREGATE name`)."
  @spec refresh_aggregate(Conn.t(), String.t()) :: :ok | {:error, atom() | Exception.t()}
  def refresh_aggregate(%Conn{} = conn, name) do
    with {:ok, [name_ok]} <- validate_idents([name]) do
      command_ok(conn, "REFRESH CONTINUOUS AGGREGATE #{name_ok}")
    end
  end

  @doc "Refreshes a continuous aggregate, raising on error."
  @spec refresh_aggregate!(Conn.t(), String.t()) :: :ok
  def refresh_aggregate!(%Conn{} = conn, name), do: bang(refresh_aggregate(conn, name))

  @doc "Drops a continuous aggregate (no `IF EXISTS` — a missing aggregate is a server error)."
  @spec drop_aggregate(Conn.t(), String.t()) :: :ok | {:error, atom() | Exception.t()}
  def drop_aggregate(%Conn{} = conn, name) do
    with {:ok, [name_ok]} <- validate_idents([name]) do
      command_ok(conn, "DROP CONTINUOUS AGGREGATE #{name_ok}")
    end
  end

  @doc "Drops a continuous aggregate, raising on error."
  @spec drop_aggregate!(Conn.t(), String.t()) :: :ok
  def drop_aggregate!(%Conn{} = conn, name), do: bang(drop_aggregate(conn, name))

  @write_opts [:precision, :timeout]
  # Wire strings for ?precision (client-validated: the server silently IGNORES an invalid value —
  # probed 26.7.2 — so this map is the only guard) and the DateTime conversion unit per precision.
  @precisions %{ns: "ns", us: "us", ms: "ms", s: "s"}
  @precision_units %{ns: :nanosecond, us: :microsecond, ms: :millisecond, s: :second}
  # Control bytes (incl. newline) split the line-protocol record — the wire has no in-string
  # escape for them (probed: a raw \n inside a quoted field parses the remainder as a NEW
  # measurement). Reject value-free wherever a caller string lands in a line. C1 controls
  # (U+0080–U+009F) are DELIBERATELY allowed: multi-byte in UTF-8, they cannot split a record —
  # the codebase's three rejection classes each serve their own embedding context (this line
  # protocol; server.ex setting values; ddl_body.ex statement text).
  @control_bytes ~r/[\x00-\x1F\x7F]/

  # The point-map contract: any OTHER key (a typo like :timestmap, or string keys) would be
  # SILENTLY ignored, dropping its clause from the line — reject value-free (Opts.validate_keys!
  # posture), naming only the allowed set.
  @point_keys [:fields, :tags, :timestamp, :type]

  # Java Long: an out-of-range integer field value or timestamp is a 204 + SILENT line drop on
  # the server (probed both signs on 26.7.2) — guard client-side, value-free, both positions.
  @int64_min -9_223_372_036_854_775_808
  @int64_max 9_223_372_036_854_775_807

  @doc """
  Writes structured `points` as InfluxDB line protocol (`POST /api/v1/ts/<db>/write`).

  Each point: `%{type: String, fields: map (REQUIRED, non-empty), tags: map \\\\ %{},
  timestamp: integer | DateTime | nil}`. Field values: integer (emits `42i`), float, boolean, or
  String; tag values: String. Type, tag and field NAMES are `Arcadic.Identifier`-validated
  (they are schema columns); atom names are allowed and converted. An integer timestamp passes
  through in the `:precision` unit; a `DateTime` is converted; `nil` omits it (server-assigned
  now). Tags and fields emit in lexicographic key order (deterministic, Influx canonical form).

  `opts`: `:precision` (`:ns` default | `:us` | `:ms` | `:s`), `:timeout` (ms).

  Read the moduledoc **Operational contract** before relying on retries or mixed-type batches.
  Value-free on every invalid input (Rule 3): shape violations raise with static messages; a bad
  name returns `{:error, :invalid_identifier}`; caller values never appear in an error.
  """
  @spec write(Conn.t(), [map()], keyword()) :: :ok | {:error, atom() | Exception.t()}
  def write(%Conn{} = conn, points, opts \\ []) do
    unless is_list(points) do
      raise ArgumentError, "points must be a list of point maps"
    end

    assert_proper_list!(points, "points")
    Opts.validate_keys!(opts, @write_opts)
    wire_precision = wire_precision!(opts)
    ts_unit = Map.fetch!(@precision_units, opts[:precision] || :ns)

    with {:ok, lines} <- build_lines(points, ts_unit) do
      dispatch_write(conn, :write, points_count(points), lines, wire_precision, opts)
    end
  end

  @doc "Writes structured points, raising on error."
  @spec write!(Conn.t(), [map()], keyword()) :: :ok
  def write!(%Conn{} = conn, points, opts \\ []), do: bang(write(conn, points, opts))

  @doc """
  Writes raw, already-built line protocol (a relay path — e.g. forwarding a Telegraf batch).
  `lines` must be a binary or iodata. arcadic performs NO validation or escaping on the content:
  this path additionally inherits the server's malformed-line silent-skip (see the moduledoc
  Operational contract). `opts`: `:precision`, `:timeout`.
  """
  @spec write_lines(Conn.t(), iodata(), keyword()) :: :ok | {:error, atom() | Exception.t()}
  def write_lines(%Conn{} = conn, lines, opts \\ []) do
    unless is_binary(lines) or is_list(lines) do
      raise ArgumentError, "lines must be a binary or iodata"
    end

    # Deep validation at the facade: a shallowly-list-shaped but INVALID iodata term would
    # otherwise crash inside the HTTP client's own :erlang.iolist_size with the ENTIRE batch
    # (caller PII) echoed in the blame (Rule 3). The computed size doubles as the
    # empty-equivalent short-circuit ([""], [[]] never hit the wire, like [] and "").
    # NOT `reraise` (credo's default suggestion): the original ArgumentError carries the value.
    size =
      case iodata_size(lines) do
        {:ok, n} -> n
        :error -> raise ArgumentError, "lines must be valid iodata"
      end

    Opts.validate_keys!(opts, @write_opts)

    lines = if size == 0, do: "", else: lines
    dispatch_write(conn, :write_lines, nil, lines, wire_precision!(opts), opts)
  end

  defp iodata_size(lines) do
    {:ok, :erlang.iolist_size(lines)}
  rescue
    ArgumentError -> :error
  end

  @doc "Writes raw line protocol, raising on error."
  @spec write_lines!(Conn.t(), iodata(), keyword()) :: :ok
  def write_lines!(%Conn{} = conn, lines, opts \\ []), do: bang(write_lines(conn, lines, opts))

  @query_opts [:from, :to, :fields, :tags, :limit, :aggregation, :bucket_interval, :timeout]
  @latest_opts [:tag, :timeout]
  # The exact server enum, UPPERCASE and case-sensitive (anything else 500s — probed 26.7.2).
  @agg_types %{sum: "SUM", avg: "AVG", min: "MIN", max: "MAX", count: "COUNT"}

  @doc """
  Time-series query (`POST /api/v1/ts/<db>/query`).

  `opts`: `:from`/`:to` (integer epoch-**milliseconds** or `DateTime` — note: milliseconds
  regardless of the type's declared PRECISION, probed), `:fields` (non-empty projection — NOTE the server
  has a live projection defect returning misaligned values under a wrong-width header; see the
  usage-rules time-series section), `:tags` (map — the server ANDs all entries; an UNKNOWN tag
  key fails open, ignored server-side), `:limit` (positive integer; server default 20000),
  `:aggregation` (`[%{field: name, type: :sum | :avg | :min | :max | :count, alias: String?}]`)
  with REQUIRED `:bucket_interval` (`t:duration/0` or a positive ms integer), `:timeout`.

  Returns the server's columnar shape with atomized keys: raw
  `{:ok, %{columns, rows, count}}`; aggregated `{:ok, %{aggregations, buckets, count}}`
  (each bucket `%{timestamp, values}`). Deliberately NOT zipped into row-maps.
  """
  @spec query(Conn.t(), String.t(), keyword()) :: {:ok, map()} | {:error, atom() | Exception.t()}
  def query(%Conn{} = conn, type, opts \\ []) do
    Opts.validate_keys!(opts, @query_opts)

    with :ok <- Identifier.validate(type),
         {:ok, body} <- query_body(type, opts) do
      dispatch_read(conn, :ts_query, :query, fn transport ->
        transport.ts_query(conn, body, Keyword.take(opts, [:timeout]))
      end)
    end
  end

  @doc "Time-series query, returning the result map or raising."
  @spec query!(Conn.t(), String.t(), keyword()) :: map()
  def query!(%Conn{} = conn, type, opts \\ []), do: bang(query(conn, type, opts))

  @doc """
  Newest point (`GET /api/v1/ts/<db>/latest`). `opts`: `:tag` — a SINGLE `{key, value}` pair
  (the substrate applies only the first tag filter; a multi-entry map is rejected — probed);
  the value must be non-empty (colon-bearing values are fine: the server splits the wire
  `key:value` on the FIRST colon and matches the remainder exactly — probed), `:timeout`.
  Returns `{:ok, %{columns, latest}}`.
  """
  @spec latest(Conn.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, atom() | Exception.t()}
  def latest(%Conn{} = conn, type, opts \\ []) do
    Opts.validate_keys!(opts, @latest_opts)

    with :ok <- Identifier.validate(type),
         {:ok, tag_params} <- latest_tag_params(opts[:tag]) do
      params = [{"type", type} | tag_params]

      dispatch_read(conn, :ts_latest, :latest, fn transport ->
        transport.ts_latest(conn, params, Keyword.take(opts, [:timeout]))
      end)
    end
  end

  @doc "Newest point, returning the result map or raising."
  @spec latest!(Conn.t(), String.t(), keyword()) :: map()
  def latest!(%Conn{} = conn, type, opts \\ []), do: bang(latest(conn, type, opts))

  @prom_opts [:time, :timeout]
  @timeout_only [:timeout]
  # The Prometheus label-name grammar (a leading underscore is legal — `__name__` is the
  # canonical metric label; `Arcadic.Identifier` would reject it). URL-path-safe by construction;
  # the transport additionally URL-encodes the path segment. The repetition is bounded to 127
  # (128 chars total, Arcadic.Identifier parity) so an unbounded label can't ride the URL path.
  @prom_label_re ~r/\A[a-zA-Z_][a-zA-Z0-9_]{0,127}\z/

  @doc """
  PromQL instant query (`GET …/prom/api/v1/query`). The PromQL text rides as a URL-encoded query
  value (data, not statement text). `opts`: `:time` (epoch-seconds integer or `DateTime`),
  `:timeout`. Returns the decoded Prometheus `data` object (`%{"resultType" => …, "result" => …}`).
  The metric name is the TIMESERIES type name; tags are labels.
  """
  @spec prom_query(Conn.t(), String.t(), keyword()) ::
          {:ok, map() | list()} | {:error, atom() | Exception.t()}
  def prom_query(%Conn{} = conn, promql, opts \\ []) do
    Opts.validate_keys!(opts, @prom_opts)
    params = [{"query", promql!(promql)}] ++ time_param(opts[:time])
    prom_get(conn, :query, :prom_query, params, opts)
  end

  @doc "PromQL instant query, returning the data or raising."
  @spec prom_query!(Conn.t(), String.t(), keyword()) :: map() | list()
  def prom_query!(%Conn{} = conn, promql, opts \\ []), do: bang(prom_query(conn, promql, opts))

  @doc """
  PromQL range query (`GET …/prom/api/v1/query_range`). `from`/`to` are epoch-seconds integers or
  `DateTime`s; `step` is an integer (seconds) or a Prometheus duration string (`"1m"`).
  """
  @spec prom_query_range(
          Conn.t(),
          String.t(),
          integer() | DateTime.t(),
          integer() | DateTime.t(),
          integer() | String.t(),
          keyword()
        ) :: {:ok, map() | list()} | {:error, atom() | Exception.t()}
  def prom_query_range(%Conn{} = conn, promql, from, to, step, opts \\ []) do
    Opts.validate_keys!(opts, @timeout_only)

    params = [
      {"query", promql!(promql)},
      {"start", epoch_s!(from, :from)},
      {"end", epoch_s!(to, :to)},
      {"step", step!(step)}
    ]

    prom_get(conn, :query_range, :prom_query_range, params, opts)
  end

  @doc "PromQL range query, returning the data or raising."
  @spec prom_query_range!(
          Conn.t(),
          String.t(),
          integer() | DateTime.t(),
          integer() | DateTime.t(),
          integer() | String.t(),
          keyword()
        ) :: map() | list()
  def prom_query_range!(%Conn{} = conn, promql, from, to, step, opts \\ []),
    do: bang(prom_query_range(conn, promql, from, to, step, opts))

  @doc "Label names (`GET …/prom/api/v1/labels`)."
  @spec prom_labels(Conn.t(), keyword()) :: {:ok, list()} | {:error, atom() | Exception.t()}
  def prom_labels(%Conn{} = conn, opts \\ []) do
    Opts.validate_keys!(opts, @timeout_only)
    prom_get(conn, :labels, :prom_labels, [], opts)
  end

  @doc "Label names, returning the list or raising."
  @spec prom_labels!(Conn.t(), keyword()) :: list()
  def prom_labels!(%Conn{} = conn, opts \\ []), do: bang(prom_labels(conn, opts))

  @doc """
  Values of one label (`GET …/prom/api/v1/label/<label>/values`). The label must match the
  Prometheus label grammar (`[a-zA-Z_][a-zA-Z0-9_]*` — `__name__` is legal).
  """
  @spec prom_label_values(Conn.t(), String.t(), keyword()) ::
          {:ok, list()} | {:error, atom() | Exception.t()}
  def prom_label_values(%Conn{} = conn, label, opts \\ []) do
    Opts.validate_keys!(opts, @timeout_only)

    unless is_binary(label) and Regex.match?(@prom_label_re, label) do
      raise ArgumentError, "label must match the Prometheus label grammar"
    end

    prom_get(conn, {:label_values, label}, :prom_label_values, [], opts)
  end

  @doc "Values of one label, returning the list or raising."
  @spec prom_label_values!(Conn.t(), String.t(), keyword()) :: list()
  def prom_label_values!(%Conn{} = conn, label, opts \\ []),
    do: bang(prom_label_values(conn, label, opts))

  @doc """
  Series matching the given selectors (`GET …/prom/api/v1/series`, repeated `match[]` params).
  `matches` is a list of non-empty selector strings (the LIST may be empty — the server answers
  an unfiltered call — but an empty-string entry is a meaningless selector and rejects).
  """
  @spec prom_series(Conn.t(), [String.t()], keyword()) ::
          {:ok, list()} | {:error, atom() | Exception.t()}
  def prom_series(%Conn{} = conn, matches, opts \\ []) do
    Opts.validate_keys!(opts, @timeout_only)

    unless is_list(matches) do
      raise ArgumentError, "matches must be a list of non-empty selector strings"
    end

    # Properness BEFORE the Enum.all? walk (an improper tail would crash it, echoing the tail).
    assert_proper_list!(matches, "matches")

    unless Enum.all?(matches, &(is_binary(&1) and &1 != "")) do
      raise ArgumentError, "matches must be a list of non-empty selector strings"
    end

    prom_get(conn, :series, :prom_series, Enum.map(matches, &{"match[]", &1}), opts)
  end

  @doc "Series matching the selectors, returning the list or raising."
  @spec prom_series!(Conn.t(), [String.t()], keyword()) :: list()
  def prom_series!(%Conn{} = conn, matches, opts \\ []),
    do: bang(prom_series(conn, matches, opts))

  # --- private: DDL assembly ---

  # :fields must be present and non-empty; :tags may be absent. Both normalize to
  # [{binary_name, binary_type}] with atom keys allowed. Static messages only (Rule 3).
  defp columns!(cols, empty_msg) do
    case normalize_columns!(cols) do
      [] -> raise ArgumentError, empty_msg
      list -> list
    end
  end

  defp optional_columns!(cols), do: normalize_columns!(cols)

  defp normalize_columns!(cols) when is_list(cols) do
    assert_proper_list!(cols, "columns")

    Enum.map(cols, fn
      {k, v} when (is_atom(k) or is_binary(k)) and is_binary(v) -> {to_string(k), v}
      _ -> raise ArgumentError, "columns must be {name, type} pairs with a string type"
    end)
  end

  defp normalize_columns!(_),
    do: raise(ArgumentError, "columns must be a list of {name, type} pairs")

  # An improper list ([elem | :tail]) satisfies is_list/1 but crashes any Enum walk with a
  # FunctionClauseError whose blame echoes the tail (Rule 3 — the list may carry PII).
  # length/1 probes properness value-free; `role` is always a static string, never the value.
  # The raise sits OUTSIDE the rescue (a `reraise` would preserve the value-bearing original).
  defp assert_proper_list!(list, role) do
    proper_list?(list) || raise(ArgumentError, "#{role} must be a proper list")
    :ok
  end

  defp proper_list?(list) do
    _ = length(list)
    true
  rescue
    ArgumentError -> false
  end

  # Validates every column name (identifier) and its TYPE token (positive allowlist — the token
  # is interpolated into DDL; an off-list token raises value-free, never echoing the input).
  defp column_clauses(cols) do
    Enum.reduce_while(cols, {:ok, []}, fn {col_name, col_type}, {:ok, acc} ->
      cond do
        Identifier.validate(col_name) != :ok -> {:halt, {:error, :invalid_identifier}}
        col_type not in @column_types -> {:halt, :bad_type}
        true -> {:cont, {:ok, ["#{col_name} #{col_type}" | acc]}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
      :bad_type -> raise ArgumentError, "unknown column type; allowed: #{inspect(@column_types)}"
    end
  end

  defp validate_idents(list) do
    Enum.reduce_while(list, {:ok, []}, fn ident, {:ok, acc} ->
      case Identifier.validate(ident) do
        :ok -> {:cont, {:ok, [ident | acc]}}
        {:error, :invalid_identifier} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end

  defp precision_clause(nil), do: ""

  defp precision_clause(p) do
    case Map.fetch(@ddl_precisions, p) do
      {:ok, token} ->
        " PRECISION #{token}"

      :error ->
        raise ArgumentError, "unknown precision; allowed: #{inspect(Map.keys(@ddl_precisions))}"
    end
  end

  defp tags_clause([]), do: ""
  defp tags_clause(cols), do: " TAGS (#{Enum.join(cols, ", ")})"

  defp shards_clause(nil), do: ""
  defp shards_clause(n) when is_integer(n) and n > 0, do: " SHARDS #{n}"
  defp shards_clause(_), do: raise(ArgumentError, "shards must be a positive integer")

  defp duration_clause(_kw, nil), do: ""
  defp duration_clause(kw, duration), do: " #{kw} #{duration_sql!(duration)}"

  defp duration_sql!({n, unit})
       when is_integer(n) and n > 0 and is_map_key(@duration_units, unit),
       do: "#{n} #{@duration_units[unit]}"

  defp duration_sql!(_),
    do:
      raise(
        ArgumentError,
        "duration must be {pos_integer, unit}; units: #{inspect(Map.keys(@duration_units))}"
      )

  defp required_duration!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, d} -> duration_sql!(d)
      :error -> raise ArgumentError, "#{key} is required"
    end
  end

  defp command_ok(conn, statement) do
    case Arcadic.command(conn, statement, %{}, language: "sql") do
      {:ok, _rows} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  # --- private: write path ---

  # The wire param is sent only when the caller passed :precision (the default :ns is the
  # server default — probed; `precision_query(nil)` on the transport omits the param). An
  # explicit value is validated client-side either way (the server silently ignores bad values).
  defp wire_precision!(opts) do
    case Keyword.fetch(opts, :precision) do
      {:ok, p} -> precision_string!(p)
      :error -> nil
    end
  end

  defp precision_string!(p) do
    case Map.fetch(@precisions, p) do
      {:ok, s} ->
        s

      :error ->
        raise ArgumentError, "unknown precision; allowed: #{inspect(Map.keys(@precisions))}"
    end
  end

  defp points_count(points), do: length(points)

  # Capability BEFORE the empty short-circuit (Bulk precedent, bulk.ex dispatch/3): Bolt + []
  # must be :not_supported, not a spurious :ok. A supported transport + [] never hits the wire.
  defp dispatch_write(%Conn{transport: transport} = conn, op, count, lines, wire_precision, opts) do
    cond do
      not callback?(transport, :ts_write, 3) ->
        {:error,
         %Error{reason: :not_supported, message: "transport does not support time-series"}}

      lines == [] or lines == "" ->
        # span/3 returns the fun's RESULT element; the empty batch never hits the wire.
        Telemetry.span(:timeseries, %{operation: op, mode: :write}, fn ->
          {:ok, %{row_count: 0, reason: :ok}}
        end)

      true ->
        Telemetry.span(:timeseries, %{operation: op, mode: :write}, fn ->
          result = transport.ts_write(conn, lines, put_precision(opts, wire_precision))
          {result, write_stop_meta(result, count)}
        end)
    end
  end

  defp put_precision(opts, nil), do: Keyword.take(opts, [:timeout])

  defp put_precision(opts, wire_precision),
    do: opts |> Keyword.take([:timeout]) |> Keyword.put(:precision, wire_precision)

  defp write_stop_meta(:ok, nil), do: %{reason: :ok}
  defp write_stop_meta(:ok, count), do: %{reason: :ok, row_count: count}

  defp write_stop_meta({:error, %{reason: reason}}, _count) when is_atom(reason),
    do: %{reason: reason}

  defp write_stop_meta({:error, _}, _count), do: %{reason: :error}

  defp callback?(transport, fun, arity),
    do: Code.ensure_loaded?(transport) and function_exported?(transport, fun, arity)

  # Builds the newline-joined lines iodata. Identifier failures return {:error, :invalid_identifier};
  # every other bad shape raises a STATIC message (a point may carry PII — never echo it).
  defp build_lines(points, ts_unit) do
    points
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn point, {:ok, acc, seen} ->
      case build_line(point, ts_unit, seen) do
        {:ok, line, seen} -> {:cont, {:ok, [line | acc], seen}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, lines, _seen} -> {:ok, lines |> Enum.reverse() |> Enum.intersperse("\n")}
      {:error, _} = err -> err
    end
  end

  defp build_line(point, ts_unit, seen) when is_map(point) do
    validate_point_keys!(point)
    type = Map.get(point, :type)
    fields = Map.get(point, :fields)
    tags = Map.get(point, :tags, %{})
    timestamp = Map.get(point, :timestamp)

    unless is_map(fields) and map_size(fields) > 0 do
      raise ArgumentError, "each point requires at least one field"
    end

    unless is_map(tags), do: raise(ArgumentError, "tags must be a map")

    with {:ok, type_name, seen} <- normalize_name(type, seen),
         {:ok, tag_part, seen} <- tag_fragment(tags, seen),
         {:ok, field_part, seen} <- field_fragment(fields, seen) do
      {:ok, [type_name, tag_part, " ", field_part, ts_fragment(timestamp, ts_unit)], seen}
    end
  end

  defp build_line(_point, _ts_unit, _seen), do: raise(ArgumentError, "each point must be a map")

  # A key outside @point_keys is a silent no-op (the typo'd clause just vanishes from the line);
  # string-keyed maps are the same hazard. Static message naming only the allowed set (Rule 3).
  defp validate_point_keys!(point) do
    case Map.keys(point) -- @point_keys do
      [] -> :ok
      _unknown -> raise ArgumentError, "point keys must be atoms among #{inspect(@point_keys)}"
    end
  end

  # Names normalize to VALIDATED binaries before any sort/interpolation: a bare `to_string/1`
  # on a non-String.Chars key (tuple/map/pid — composite keys can embed PII) crashes with a
  # Protocol.UndefinedError instead of the value-free {:error, :invalid_identifier} contract.
  # `seen` threads the batch's already-validated names (identifier validity is name-intrinsic),
  # so each distinct type/tag/field name validates ONCE per batch (~55% on the write bench).
  defp normalize_name(name, seen) when is_binary(name) do
    if MapSet.member?(seen, name) do
      {:ok, name, seen}
    else
      case Identifier.validate(name) do
        :ok -> {:ok, name, MapSet.put(seen, name)}
        {:error, _} = err -> err
      end
    end
  end

  defp normalize_name(name, seen) when is_atom(name) and not is_nil(name),
    do: normalize_name(Atom.to_string(name), seen)

  defp normalize_name(_, _seen), do: {:error, :invalid_identifier}

  # Validates + normalizes every key FIRST (see normalize_name/2), then sorts, then rejects a
  # post-normalization duplicate (an atom key and its string twin would emit the name twice —
  # a silently malformed line). Static raise: a duplicate NAME is already identifier-validated.
  defp normalized_pairs(map, seen) do
    map
    |> Enum.reduce_while({:ok, [], seen}, fn {k, v}, {:ok, acc, seen} ->
      case normalize_name(k, seen) do
        {:ok, name, seen} -> {:cont, {:ok, [{name, v} | acc], seen}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, pairs, seen} -> {:ok, sorted_unique!(pairs), seen}
      {:error, _} = err -> err
    end
  end

  defp sorted_unique!(pairs) do
    sorted = Enum.sort_by(pairs, &elem(&1, 0))

    if Enum.uniq_by(sorted, &elem(&1, 0)) != sorted do
      raise ArgumentError, "duplicate tag/field name after atom-key normalization"
    end

    sorted
  end

  defp tag_fragment(tags, seen) when map_size(tags) == 0, do: {:ok, "", seen}

  defp tag_fragment(tags, seen) do
    with {:ok, pairs, seen} <- normalized_pairs(tags, seen) do
      {:ok, Enum.map_join(pairs, fn {k, v} -> ",#{k}=#{escape_tag_value!(v)}" end), seen}
    end
  end

  defp field_fragment(fields, seen) do
    with {:ok, pairs, seen} <- normalized_pairs(fields, seen) do
      {:ok, Enum.map_join(pairs, ",", fn {k, v} -> "#{k}=#{field_value!(v)}" end), seen}
    end
  end

  defp ts_fragment(nil, _unit), do: ""

  defp ts_fragment(ts, _unit) when is_integer(ts) and ts >= @int64_min and ts <= @int64_max,
    do: " #{ts}"

  defp ts_fragment(ts, _unit) when is_integer(ts),
    do: raise(ArgumentError, "timestamps must fit int64")

  # Delegating the CONVERTED value through the integer clauses applies the int64 bound here too:
  # DateTime CAN overflow (a year-2263+ DateTime at :ns converts past int64_max — verified).
  defp ts_fragment(%DateTime{} = dt, unit), do: ts_fragment(DateTime.to_unix(dt, unit), unit)

  defp ts_fragment(_, _),
    do: raise(ArgumentError, "timestamp must be an integer, DateTime, or nil")

  # Tag values ride unquoted: escape backslash FIRST, then the delimiters. Control bytes reject.
  # An EMPTY tag value emits `,k=` — a silently malformed line — so it rejects too (static).
  defp escape_tag_value!(""), do: raise(ArgumentError, "tag values must be non-empty strings")

  defp escape_tag_value!(v) when is_binary(v) do
    reject_control!(v)

    v
    |> String.replace("\\", "\\\\")
    |> String.replace(",", "\\,")
    |> String.replace("=", "\\=")
    |> String.replace(" ", "\\ ")
  end

  defp escape_tag_value!(_), do: raise(ArgumentError, "tag values must be strings")

  defp field_value!(v) when is_integer(v) and v >= @int64_min and v <= @int64_max, do: "#{v}i"

  defp field_value!(v) when is_integer(v),
    do: raise(ArgumentError, "integer field values must fit int64")

  defp field_value!(v) when is_float(v), do: to_string(v)
  defp field_value!(v) when is_boolean(v), do: to_string(v)

  defp field_value!(v) when is_binary(v) do
    reject_control!(v)
    escaped = v |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
    "\"#{escaped}\""
  end

  defp field_value!(_),
    do: raise(ArgumentError, "field values must be integers, floats, booleans, or strings")

  defp reject_control!(v) do
    if not String.valid?(v) or Regex.match?(@control_bytes, v) do
      raise ArgumentError, "string values must be UTF-8 without control bytes"
    end

    :ok
  end

  # --- private: read path ---

  # All /ts reads share the capability check + :timeseries read span. `arity` is 3 for ts_query/
  # ts_latest; ts_prom_get (T6) passes 4.
  defp dispatch_read(%Conn{transport: transport}, callback, op, fun, arity \\ 3) do
    if callback?(transport, callback, arity) do
      Telemetry.span(:timeseries, %{operation: op, mode: :read}, fn ->
        result = fun.(transport)
        {result, read_stop_meta(result)}
      end)
    else
      {:error, %Error{reason: :not_supported, message: "transport does not support time-series"}}
    end
  end

  defp read_stop_meta({:ok, %{count: count}}) when is_integer(count),
    do: %{reason: :ok, row_count: count}

  # The list clause is unreachable from ts_query/ts_latest (map successes); the prom_* reads
  # (T6), whose data envelopes unwrap to lists, land here (span-asserted in the unit suite).
  defp read_stop_meta({:ok, list}) when is_list(list), do: %{reason: :ok, row_count: length(list)}
  defp read_stop_meta({:ok, _}), do: %{reason: :ok}
  defp read_stop_meta({:error, %{reason: reason}}) when is_atom(reason), do: %{reason: reason}
  defp read_stop_meta({:error, _}), do: %{reason: :error}

  defp query_body(type, opts) do
    with {:ok, fields} <- query_fields(opts[:fields]),
         {:ok, tags} <- query_tags(opts[:tags]),
         {:ok, aggregation} <- aggregation_object(opts[:aggregation], opts[:bucket_interval]) do
      body =
        %{"type" => type}
        |> put_present("from", to_ms!(opts[:from], :from))
        |> put_present("to", to_ms!(opts[:to], :to))
        |> put_present("fields", fields)
        |> put_present("tags", tags)
        |> put_present("limit", query_limit!(opts[:limit]))
        |> put_present("aggregation", aggregation)

      {:ok, body}
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp to_ms!(nil, _label), do: nil
  defp to_ms!(ms, _label) when is_integer(ms), do: ms
  defp to_ms!(%DateTime{} = dt, _label), do: DateTime.to_unix(dt, :millisecond)

  defp to_ms!(_, label),
    do: raise(ArgumentError, "#{label} must be an epoch-ms integer or DateTime")

  defp query_limit!(nil), do: nil
  defp query_limit!(n) when is_integer(n) and n > 0, do: n
  defp query_limit!(_), do: raise(ArgumentError, "limit must be a positive integer")

  defp query_fields(nil), do: {:ok, nil}

  # An empty projection would ship "fields": [] into the endpoint's KNOWN projection defect
  # (misaligned values under a wrong-width header) — reject, consistent with the DDL column rule.
  defp query_fields([]),
    do: raise(ArgumentError, "fields must be a non-empty list of column names")

  # No `with` wrapper: validate_idents/1 already returns the exact {:ok, list} | {:error, _}
  # shape (a redundant `with` fails credo --strict Refactor.RedundantWithClauseResult).
  defp query_fields(fields) when is_list(fields) do
    assert_proper_list!(fields, "fields")
    validate_idents(Enum.map(fields, &name_string!/1))
  end

  defp query_fields(_), do: raise(ArgumentError, "fields must be a list of column names")

  defp query_tags(nil), do: {:ok, nil}

  # An empty tags map is ABSENT (omit "tags" from the body entirely), not an empty filter —
  # `tags: %{}` and no `:tags` opt mean the same thing to the caller.
  defp query_tags(tags) when is_map(tags) and map_size(tags) == 0, do: {:ok, nil}

  # Post-normalization duplicate keys (an atom key and its string twin) reject, mirroring the
  # write path's sorted_unique!/1 — a silent last-wins would be iteration-order-dependent.
  defp query_tags(tags) when is_map(tags) do
    tags
    |> Enum.reduce_while({:ok, %{}}, fn {k, v}, {:ok, acc} ->
      key = name_string!(k)

      cond do
        Identifier.validate(key) != :ok ->
          {:halt, {:error, :invalid_identifier}}

        not is_binary(v) ->
          raise ArgumentError, "tag values must be strings"

        is_map_key(acc, key) ->
          raise ArgumentError, "duplicate tag name after atom-key normalization"

        true ->
          {:cont, {:ok, Map.put(acc, key, v)}}
      end
    end)
  end

  defp query_tags(_), do: raise(ArgumentError, "tags must be a map")

  # Deliberate divergence from the write path's normalize_name/1: read-path name SHAPE
  # violations raise a static ArgumentError, while normalize_name returns
  # {:error, :invalid_identifier} (the shipped T5 contract). Keep the two in conscious sync —
  # do not let their behaviors drift silently.
  defp name_string!(name) when is_binary(name), do: name
  defp name_string!(name) when is_atom(name) and not is_nil(name), do: to_string(name)
  defp name_string!(_), do: raise(ArgumentError, "names must be strings or atoms")

  defp aggregation_object(nil, nil), do: {:ok, nil}

  # A bucket_interval WITHOUT aggregation would otherwise be silently dropped from the body.
  defp aggregation_object(nil, _interval),
    do: raise(ArgumentError, "bucket_interval requires :aggregation")

  defp aggregation_object(requests, interval) when is_list(requests) and requests != [] do
    assert_proper_list!(requests, "aggregation")
    ms = bucket_interval_ms!(interval)

    requests
    |> Enum.reduce_while({:ok, []}, fn req, {:ok, acc} ->
      case agg_request(req) do
        {:ok, wire} -> {:cont, {:ok, [wire | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, wires} ->
        wires = Enum.reverse(wires)
        assert_unique_outputs!(wires)
        {:ok, %{"bucketInterval" => ms, "requests" => wires}}

      {:error, _} = err ->
        err
    end
  end

  defp aggregation_object(_, _),
    do: raise(ArgumentError, "aggregation must be a non-empty list of request maps")

  # Effective output identity: the alias when present, else the {field, type} pair — the server's
  # default column name incorporates BOTH (e.g. "u_avg"), so avg+max on one un-aliased field is
  # NOT a collision. Colliding outputs would produce indistinguishable response columns.
  defp assert_unique_outputs!(wires) do
    keys = Enum.map(wires, fn wire -> Map.get(wire, "alias") || {wire["field"], wire["type"]} end)

    if Enum.uniq(keys) != keys do
      raise ArgumentError, "duplicate aggregation output (alias or un-aliased field+type pair)"
    end

    :ok
  end

  defp agg_request(%{field: field, type: type} = req) do
    agg_type =
      Map.get(@agg_types, type) ||
        raise(
          ArgumentError,
          "unknown aggregation type; allowed: #{inspect(Map.keys(@agg_types))}"
        )

    field_name = name_string!(field)

    with :ok <- Identifier.validate(field_name) do
      wire = %{"field" => field_name, "type" => agg_type}

      case Map.get(req, :alias) do
        nil -> {:ok, wire}
        a when is_binary(a) -> {:ok, Map.put(wire, "alias", a)}
        _ -> raise ArgumentError, "alias must be a string"
      end
    end
  end

  defp agg_request(_),
    do: raise(ArgumentError, "each aggregation request needs :field and :type")

  defp bucket_interval_ms!({n, unit})
       when is_integer(n) and n > 0 and is_map_key(@duration_units, unit) do
    n * unit_ms(unit)
  end

  defp bucket_interval_ms!(ms) when is_integer(ms) and ms > 0, do: ms

  defp bucket_interval_ms!(_),
    do:
      raise(
        ArgumentError,
        "bucket_interval is required with aggregation: {n, unit} or a positive ms integer"
      )

  defp unit_ms(:seconds), do: 1_000
  defp unit_ms(:minutes), do: 60_000
  defp unit_ms(:hours), do: 3_600_000
  defp unit_ms(:days), do: 86_400_000

  defp latest_tag_params(nil), do: {:ok, []}

  # The tag rides a "key:value" micro-format. PROBED (26.7.2, S13 closeout A4): the server
  # splits on the FIRST colon and matches the remainder EXACTLY — writing host="a:b" then
  # `tag=host:a:b` returns that point, while `tag=host:a` matches only host="a" — so
  # colon-bearing VALUES are allowed (the key is Identifier-validated, colon-free by grammar,
  # making the first-colon split unambiguous). An empty value ("host:") stays rejected,
  # value-free: it would be a silently wrong filter.
  defp latest_tag_params({k, v}) do
    key = name_string!(k)

    cond do
      Identifier.validate(key) != :ok -> {:error, :invalid_identifier}
      not is_binary(v) -> raise ArgumentError, "the tag value must be a string"
      v == "" -> raise ArgumentError, "the tag value must be a non-empty string"
      true -> {:ok, [{"tag", "#{key}:#{v}"}]}
    end
  end

  defp latest_tag_params(%{} = tags) when map_size(tags) > 1,
    do:
      raise(
        ArgumentError,
        "latest supports a single tag ({key, value}) — the server applies only the first tag filter"
      )

  defp latest_tag_params(%{} = tags) when map_size(tags) == 1,
    do: tags |> Enum.at(0) |> latest_tag_params()

  defp latest_tag_params(_),
    do: raise(ArgumentError, "tag must be a {key, value} tuple")

  # --- private: prom path ---

  defp prom_get(conn, wire_op, span_op, params, opts) do
    dispatch_read(
      conn,
      :ts_prom_get,
      span_op,
      fn transport ->
        transport.ts_prom_get(conn, wire_op, params, Keyword.take(opts, [:timeout]))
      end,
      4
    )
  end

  # An empty PromQL text is never a valid query — reject client-side (static, value-free),
  # consistent with the module's empty-string rules (tag values, DDL columns).
  defp promql!(""), do: raise(ArgumentError, "the PromQL query must be a non-empty string")
  defp promql!(q) when is_binary(q), do: q
  defp promql!(_), do: raise(ArgumentError, "the PromQL query must be a string")

  defp time_param(nil), do: []
  defp time_param(t), do: [{"time", epoch_s!(t, :time)}]

  defp epoch_s!(s, _label) when is_integer(s), do: Integer.to_string(s)

  defp epoch_s!(%DateTime{} = dt, _label),
    do: dt |> DateTime.to_unix(:second) |> Integer.to_string()

  defp epoch_s!(_, label),
    do: raise(ArgumentError, "#{label} must be an epoch-seconds integer or DateTime")

  # Integers validate fully client-side; duration STRINGS only reject the empty case (static) —
  # the server owns the duration grammar, so no client-side parse beyond non-emptiness.
  defp step!(s) when is_integer(s) and s > 0, do: Integer.to_string(s)
  defp step!(""), do: raise(ArgumentError, "step must be a non-empty duration string")
  defp step!(s) when is_binary(s), do: s
  defp step!(_), do: raise(ArgumentError, "step must be a positive integer or duration string")

  # Shared bang: :ok passthrough; {:ok, value} unwrap (consumed by query!/latest!/prom_*! in
  # later tasks — NOT dead code); exceptions reraise; bare atoms get a static message.
  # A hidden-public `def` (not `defp`): every caller at THIS commit returns `:ok | {:error, _}`,
  # so dialyzer call-site-narrows a private bang/1 and flags the `{:ok, value}` clause as
  # unmatchable (pattern_match). Exporting it keeps the forward-consumed clause verbatim with
  # dialyzer green — no ignore file, no `@dialyzer` suppression (the changes.ex convention) —
  # and the `@doc false` below keeps it off the hexdocs API surface.
  @doc false
  def bang(:ok), do: :ok
  def bang({:ok, value}), do: value
  def bang({:error, %{__exception__: true} = error}), do: raise(error)

  def bang({:error, reason}) when is_atom(reason),
    do: raise(ArgumentError, "time-series operation failed: #{inspect(reason)}")

  # A non-atom reason may carry caller data — static message only, never inspect it (Rule 3).
  def bang({:error, _reason}), do: raise(ArgumentError, "time-series operation failed")
end
