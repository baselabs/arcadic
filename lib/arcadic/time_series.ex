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
  # measurement). Reject value-free wherever a caller string lands in a line.
  @control_bytes ~r/[\x00-\x1F\x7F]/

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

    Opts.validate_keys!(opts, @write_opts)

    dispatch_write(conn, :write_lines, nil, lines, wire_precision!(opts), opts)
  end

  @doc "Writes raw line protocol, raising on error."
  @spec write_lines!(Conn.t(), iodata(), keyword()) :: :ok
  def write_lines!(%Conn{} = conn, lines, opts \\ []), do: bang(write_lines(conn, lines, opts))

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
    Enum.map(cols, fn
      {k, v} when (is_atom(k) or is_binary(k)) and is_binary(v) -> {to_string(k), v}
      _ -> raise ArgumentError, "columns must be {name, type} pairs with a string type"
    end)
  end

  defp normalize_columns!(_),
    do: raise(ArgumentError, "columns must be a list of {name, type} pairs")

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
    |> Enum.reduce_while({:ok, []}, fn point, {:ok, acc} ->
      case build_line(point, ts_unit) do
        {:ok, line} -> {:cont, {:ok, [line | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, lines} -> {:ok, lines |> Enum.reverse() |> Enum.intersperse("\n")}
      {:error, _} = err -> err
    end
  end

  defp build_line(point, ts_unit) when is_map(point) do
    type = Map.get(point, :type)
    fields = Map.get(point, :fields)
    tags = Map.get(point, :tags, %{})
    timestamp = Map.get(point, :timestamp)

    unless is_map(fields) and map_size(fields) > 0 do
      raise ArgumentError, "each point requires at least one field"
    end

    unless is_map(tags), do: raise(ArgumentError, "tags must be a map")

    with {:ok, type_name} <- normalize_name(type),
         {:ok, tag_part} <- tag_fragment(tags),
         {:ok, field_part} <- field_fragment(fields) do
      {:ok, [type_name, tag_part, " ", field_part, ts_fragment(timestamp, ts_unit)]}
    end
  end

  defp build_line(_point, _ts_unit), do: raise(ArgumentError, "each point must be a map")

  # Names normalize to VALIDATED binaries before any sort/interpolation: a bare `to_string/1`
  # on a non-String.Chars key (tuple/map/pid — composite keys can embed PII) crashes with a
  # Protocol.UndefinedError instead of the value-free {:error, :invalid_identifier} contract.
  defp normalize_name(name) when is_binary(name) do
    case Identifier.validate(name) do
      :ok -> {:ok, name}
      {:error, _} = err -> err
    end
  end

  defp normalize_name(name) when is_atom(name) and not is_nil(name),
    do: normalize_name(Atom.to_string(name))

  defp normalize_name(_), do: {:error, :invalid_identifier}

  # Validates + normalizes every key FIRST (see normalize_name/1), then sorts, then rejects a
  # post-normalization duplicate (an atom key and its string twin would emit the name twice —
  # a silently malformed line). Static raise: a duplicate NAME is already identifier-validated.
  defp normalized_pairs(map) do
    map
    |> Enum.reduce_while({:ok, []}, fn {k, v}, {:ok, acc} ->
      case normalize_name(k) do
        {:ok, name} -> {:cont, {:ok, [{name, v} | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, sorted_unique!(pairs)}
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

  defp tag_fragment(tags) when map_size(tags) == 0, do: {:ok, ""}

  defp tag_fragment(tags) do
    with {:ok, pairs} <- normalized_pairs(tags) do
      {:ok, Enum.map_join(pairs, fn {k, v} -> ",#{k}=#{escape_tag_value!(v)}" end)}
    end
  end

  defp field_fragment(fields) do
    with {:ok, pairs} <- normalized_pairs(fields) do
      {:ok, Enum.map_join(pairs, ",", fn {k, v} -> "#{k}=#{field_value!(v)}" end)}
    end
  end

  defp ts_fragment(nil, _unit), do: ""
  defp ts_fragment(ts, _unit) when is_integer(ts), do: " #{ts}"
  defp ts_fragment(%DateTime{} = dt, unit), do: " #{DateTime.to_unix(dt, unit)}"

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

  defp field_value!(v) when is_integer(v), do: "#{v}i"
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

  def bang({:error, reason}),
    do: raise(ArgumentError, "time-series operation failed: #{inspect(reason)}")
end
