defmodule Arcadic.Vector do
  @moduledoc """
  ArcadeDB dense vector search — tenant-blind index DDL and nearest-neighbour /
  hybrid-fusion query builders over ArcadeDB's `LSM_VECTOR` surface.

  Every caller value (query vector, `k`, `ef_search`, `max_distance`) binds as a
  `$param`. The only text interpolated into a statement is the index reference
  `"Type[property]"`, whose two identifiers are `Arcadic.Identifier`-validated before
  composition — the sole injection surface, closed by construction (callers pass
  `type`/`property`, never a raw ref). Index metadata values (`dimensions`, the
  similarity/encoding/quantization enums) are developer-supplied schema config,
  validated against integer/allowlist checks before interpolation. Failures carry the
  invalid SHAPE only, never the offending value (AGENTS.md Critical Rule 3).
  """
  alias Arcadic.{Conn, Identifier, Opts}

  @doc "Builds the ArcadeDB index reference `\"Type[property]\"`, validating both identifiers."
  @spec index_ref(String.t(), String.t()) :: {:ok, String.t()} | {:error, :invalid_identifier}
  def index_ref(type, property) do
    with :ok <- Identifier.validate(type),
         :ok <- Identifier.validate(property) do
      {:ok, "#{type}[#{property}]"}
    end
  end

  @similarities %{cosine: "COSINE", dot_product: "DOT_PRODUCT", euclidean: "EUCLIDEAN"}
  @encodings %{float32: "FLOAT32", int8: "INT8"}
  @quantizations %{none: "NONE", int8: "INT8", binary: "BINARY", product: "PRODUCT"}
  @index_opts [:similarity, :encoding, :quantization, :max_connections, :beam_width]

  @sparse_index_opts [:dimensions, :modifier]
  @sparse_modifiers %{none: "NONE", idf: "IDF"}

  @doc """
  Creates a dense `LSM_VECTOR` index (idempotent — `IF NOT EXISTS`). `opts`:
  `similarity` (`:cosine` default | `:dot_product` | `:euclidean`), `encoding`
  (`:float32` | `:int8`), `quantization` (`:none` | `:int8` | `:binary` | `:product`),
  `max_connections` (default 16), `beam_width` (default 100). Unknown opt keys are
  rejected value-free (the server silently accepts unknown METADATA keys).
  """
  @spec create_dense_index(Conn.t(), String.t(), String.t(), pos_integer(), keyword()) ::
          :ok | {:error, atom() | Exception.t()}
  def create_dense_index(%Conn{} = conn, type, property, dimensions, opts \\ []) do
    with {:ok, _ref} <- index_ref(type, property) do
      metadata = build_metadata(dimensions, opts)

      command_ok(
        conn,
        "CREATE INDEX IF NOT EXISTS ON #{type} (#{property}) LSM_VECTOR METADATA {#{metadata}}"
      )
    end
  end

  @doc "Creates a dense vector index, raising on error."
  @spec create_dense_index!(Conn.t(), String.t(), String.t(), pos_integer(), keyword()) :: :ok
  def create_dense_index!(%Conn{} = conn, type, property, dimensions, opts \\ []),
    do: bang(create_dense_index(conn, type, property, dimensions, opts))

  @doc "Drops a dense vector index (idempotent — `IF EXISTS`)."
  @spec drop_dense_index(Conn.t(), String.t(), String.t()) ::
          :ok | {:error, atom() | Exception.t()}
  def drop_dense_index(%Conn{} = conn, type, property) do
    with {:ok, ref} <- index_ref(type, property) do
      command_ok(conn, "DROP INDEX `#{ref}` IF EXISTS")
    end
  end

  @doc "Drops a dense vector index, raising on error."
  @spec drop_dense_index!(Conn.t(), String.t(), String.t()) :: :ok
  def drop_dense_index!(%Conn{} = conn, type, property),
    do: bang(drop_dense_index(conn, type, property))

  @doc "Builds the sparse index ref `\"Type[tokens,weights]\"`, validating all three identifiers."
  @spec sparse_index_ref(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :invalid_identifier}
  def sparse_index_ref(type, tokens_property, weights_property) do
    with :ok <- Identifier.validate(type),
         :ok <- Identifier.validate(tokens_property),
         :ok <- Identifier.validate(weights_property) do
      {:ok, "#{type}[#{tokens_property},#{weights_property}]"}
    end
  end

  @doc """
  Creates an `LSM_SPARSE_VECTOR` index over a `(tokens, weights)` property pair. `opts`:
  `dimensions` (pos_integer, optional) and `modifier` (`:none` default | `:idf`). Both are
  omitted from the DDL when not given (server defaults apply).

  **Coverage caveat (ArcadeDB semantic):** a sparse index does NOT index rows that existed
  BEFORE it was created — only rows inserted or updated afterwards are searchable (the DDL's
  reported index count is misleading, and `REBUILD INDEX` throws on a sparse index). Create the
  index before loading, or re-touch pre-existing rows. When the DDL reports pre-existing rows,
  a value-free `[:arcadic, :vector, :sparse_index_preexisting]` telemetry event is emitted.
  """
  @spec create_sparse_index(Conn.t(), String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, atom() | Exception.t()}
  def create_sparse_index(%Conn{} = conn, type, tokens_property, weights_property, opts \\ []) do
    with {:ok, _ref} <- sparse_index_ref(type, tokens_property, weights_property) do
      metadata = build_sparse_metadata(opts)

      case Arcadic.command(
             conn,
             "CREATE INDEX ON #{type} (#{tokens_property}, #{weights_property}) LSM_SPARSE_VECTOR#{metadata}",
             %{},
             language: "sql"
           ) do
        {:ok, rows} ->
          maybe_signal_preexisting(rows)
          :ok

        {:error, error} ->
          {:error, error}
      end
    end
  end

  @doc "Creates a sparse vector index, raising on error."
  @spec create_sparse_index!(Conn.t(), String.t(), String.t(), String.t(), keyword()) :: :ok
  def create_sparse_index!(%Conn{} = conn, type, tokens_property, weights_property, opts \\ []),
    do: bang(create_sparse_index(conn, type, tokens_property, weights_property, opts))

  @doc "Drops a sparse vector index (idempotent — `IF EXISTS`)."
  @spec drop_sparse_index(Conn.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, atom() | Exception.t()}
  def drop_sparse_index(%Conn{} = conn, type, tokens_property, weights_property) do
    with {:ok, ref} <- sparse_index_ref(type, tokens_property, weights_property) do
      command_ok(conn, "DROP INDEX `#{ref}` IF EXISTS")
    end
  end

  @doc "Drops a sparse vector index, raising on error."
  @spec drop_sparse_index!(Conn.t(), String.t(), String.t(), String.t()) :: :ok
  def drop_sparse_index!(%Conn{} = conn, type, tokens_property, weights_property),
    do: bang(drop_sparse_index(conn, type, tokens_property, weights_property))

  @query_opts [:ef_search, :max_distance, :filter, :group_by, :group_size]

  @doc """
  Runs a dense nearest-neighbour search, returning rows ranked closest-first (each
  carries the vertex's top-level fields plus `distance`). `query_vector` and `k` bind
  as params. `opts`: `ef_search` (pos_integer), `max_distance` (number), `filter`
  (non-empty list of `#<bucket>:<pos>` candidate RID strings — restricts the search to
  that candidate set), `group_by` (property name to group results by; validated for
  identifier shape), `group_size` (pos_integer — max results per group). All bind as
  params inside the query-options object.

  `distance` (and therefore `max_distance`) semantics depend on the index's
  `similarity`: COSINE yields `0..1` ascending (0 = identical); DOT_PRODUCT yields
  NEGATIVE values (≈ -1 identical, less-negative = farther), so a small positive
  `max_distance` filters nothing; EUCLIDEAN differs again. Choose thresholds per the
  index's similarity.
  """
  @spec neighbors(Conn.t(), String.t(), String.t(), [number()], pos_integer(), keyword()) ::
          {:ok, [map()]} | {:error, atom() | Exception.t()}
  def neighbors(%Conn{} = conn, type, property, query_vector, k, opts \\ []) do
    with {:ok, ref} <- index_ref(type, property) do
      k = require_pos_int!(k, "k")
      query_vector = require_list!(query_vector, "query_vector")
      {opt_obj, opt_params} = build_query_opts(opts, @query_opts)
      sql = "SELECT expand(vector.neighbors('#{ref}', :vec, :k#{opt_obj}))"

      Arcadic.query(conn, sql, Map.merge(%{"vec" => query_vector, "k" => k}, opt_params),
        language: "sql"
      )
    end
  end

  @doc "Runs a dense nearest-neighbour search, returning rows or raising."
  @spec neighbors!(Conn.t(), String.t(), String.t(), [number()], pos_integer(), keyword()) :: [
          map()
        ]
  def neighbors!(%Conn{} = conn, type, property, query_vector, k, opts \\ []),
    do: bang(neighbors(conn, type, property, query_vector, k, opts))

  @sparse_query_opts [:filter, :group_by, :group_size]

  @doc """
  Runs a sparse (learned-sparse / BM25-style) nearest-neighbour search over an
  `LSM_SPARSE_VECTOR` index, returning rows ranked by a top-level **`score`** (higher = better;
  there is no `distance`). `query_tokens`/`query_weights`/`k` bind as params. `opts`: `filter`
  (candidate RID set), `group_by`, `group_size` — `ef_search`/`max_distance` are not accepted
  (rejected client-side value-free). See `create_sparse_index/5` for the index coverage caveat.
  """
  @spec sparse_neighbors(
          Conn.t(),
          String.t(),
          String.t(),
          String.t(),
          [integer()],
          [number()],
          pos_integer(),
          keyword()
        ) :: {:ok, [map()]} | {:error, atom() | Exception.t()}
  def sparse_neighbors(
        %Conn{} = conn,
        type,
        tokens_property,
        weights_property,
        query_tokens,
        query_weights,
        k,
        opts \\ []
      ) do
    with {:ok, ref} <- sparse_index_ref(type, tokens_property, weights_property) do
      k = require_pos_int!(k, "k")
      query_tokens = require_list!(query_tokens, "query_tokens")
      query_weights = require_list!(query_weights, "query_weights")
      {opt_obj, opt_params} = build_query_opts(opts, @sparse_query_opts)
      sql = "SELECT expand(vector.sparseNeighbors('#{ref}', :toks, :wts, :k#{opt_obj}))"

      Arcadic.query(
        conn,
        sql,
        Map.merge(%{"toks" => query_tokens, "wts" => query_weights, "k" => k}, opt_params),
        language: "sql"
      )
    end
  end

  @doc "Runs a sparse nearest-neighbour search, returning rows or raising."
  @spec sparse_neighbors!(
          Conn.t(),
          String.t(),
          String.t(),
          String.t(),
          [integer()],
          [number()],
          pos_integer(),
          keyword()
        ) :: [map()]
  def sparse_neighbors!(
        %Conn{} = conn,
        type,
        tokens_property,
        weights_property,
        query_tokens,
        query_weights,
        k,
        opts \\ []
      ),
      do:
        bang(
          sparse_neighbors(
            conn,
            type,
            tokens_property,
            weights_property,
            query_tokens,
            query_weights,
            k,
            opts
          )
        )

  @fusions %{rrf: "RRF", dbsf: "DBSF", linear: "LINEAR"}
  @fuse_opts [:fusion, :weights, :k, :filter, :group_by, :group_size]

  @doc """
  Runs a hybrid fusion over dense neighbour subqueries. `neighbor_specs` is a non-empty
  list of `{type, property, query_vector, k}`, each built as a validated `vector.neighbors`
  subquery with distinct indexed params. `opts`: `fusion` (`:rrf` default | `:dbsf` |
  `:linear`), `weights` (list of numbers), `k` (pos_integer), `filter` (non-empty list of
  `#<bucket>:<pos>` candidate RID strings — a SHARED candidate set threaded into every
  subquery), `group_by` (property name to group by; validated for identifier shape),
  `group_size` (pos_integer — max results per group). `group_by`/`group_size` apply to the
  FUSED output (the outer fuse object); all bind as params.

  Fused rows are ranked by ArcadeDB's fusion `score` (higher = better) rather than the
  `distance` that `neighbors/6` returns.

  `neighbor_specs` and `weights` are trusted developer-supplied config: the emitted
  statement grows linearly with their length (no cap), matching arcadic's
  no-statement-size-limit posture elsewhere.
  """
  @spec fuse(Conn.t(), [{String.t(), String.t(), [number()], pos_integer()}], keyword()) ::
          {:ok, [map()]} | {:error, atom() | Exception.t()}
  def fuse(%Conn{} = conn, neighbor_specs, opts \\ []) do
    Opts.validate_keys!(opts, @fuse_opts)
    fusion = enum!(@fusions, Keyword.get(opts, :fusion, :rrf), "fusion")
    filter = fuse_filter!(opts)
    {group_frag, group_params} = fuse_group_opts(opts)

    with {:ok, subqueries, params} <- build_subqueries(neighbor_specs, filter != nil) do
      params =
        params
        |> maybe_put_filter(filter)
        |> Map.merge(group_params)

      sql =
        "SELECT expand(vector.fuse(#{Enum.join(subqueries, ", ")}, " <>
          "{#{fuse_opts(fusion, opts)}#{group_frag}}))"

      Arcadic.query(conn, sql, params, language: "sql")
    end
  end

  defp fuse_filter!(opts) do
    case Keyword.fetch(opts, :filter) do
      :error -> nil
      {:ok, rids} -> validate_rids!(rids)
    end
  end

  defp maybe_put_filter(params, nil), do: params
  defp maybe_put_filter(params, rids), do: Map.put(params, "rids", rids)

  # group_by/group_size ride the OUTER fuse object (grouping the fused output), param-bound.
  defp fuse_group_opts(opts) do
    Enum.reduce([:group_by, :group_size], {"", %{}}, fn key, {frag, params} ->
      case Keyword.fetch(opts, key) do
        :error -> {frag, params}
        {:ok, value} -> add_fuse_group_opt(key, value, frag, params)
      end
    end)
  end

  defp add_fuse_group_opt(:group_by, value, frag, params),
    do: {frag <> ", groupBy: :gb", Map.put(params, "gb", validate_group_by!(value))}

  defp add_fuse_group_opt(:group_size, value, frag, params),
    do: {frag <> ", groupSize: :gs", Map.put(params, "gs", require_pos_int!(value, "group_size"))}

  @doc "Runs a hybrid fusion, returning rows or raising."
  @spec fuse!(Conn.t(), [{String.t(), String.t(), [number()], pos_integer()}], keyword()) :: [
          map()
        ]
  def fuse!(%Conn{} = conn, neighbor_specs, opts \\ []),
    do: bang(fuse(conn, neighbor_specs, opts))

  # --- private ---

  defp build_subqueries(specs, with_filter) when is_list(specs) and specs != [] do
    opt = if with_filter, do: ", {filter: :rids}", else: ""

    specs
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], %{}}, fn {spec, i}, {:ok, subs, params} ->
      {type, property, vec, k} = require_spec!(spec)

      case index_ref(type, property) do
        {:ok, ref} ->
          k = require_pos_int!(k, "k")
          vec = require_list!(vec, "query_vector")
          sub = "(SELECT expand(vector.neighbors('#{ref}', :vec#{i}, :k#{i}#{opt})))"
          {:cont, {:ok, [sub | subs], Map.merge(params, %{"vec#{i}" => vec, "k#{i}" => k})}}

        {:error, :invalid_identifier} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, subs, params} -> {:ok, Enum.reverse(subs), params}
      {:error, _} = err -> err
    end
  end

  defp build_subqueries(_specs, _with_filter) do
    raise ArgumentError,
          "neighbor_specs must be a non-empty list of {type, property, query_vector, k} tuples"
  end

  defp require_spec!({_type, _property, _vec, _k} = spec), do: spec

  defp require_spec!(_spec),
    do:
      raise(
        ArgumentError,
        "each neighbor_spec must be a {type, property, query_vector, k} tuple"
      )

  # fusion + optional weights (validated numbers) + k (validated int), interpolated as
  # developer-supplied fusion config (not caller data).
  defp fuse_opts(fusion, opts) do
    "fusion:'#{fusion}'"
    |> maybe_weights(opts)
    |> maybe_fuse_k(opts)
  end

  defp maybe_weights(acc, opts) do
    case Keyword.fetch(opts, :weights) do
      :error ->
        acc

      {:ok, weights} ->
        weights = require_list!(weights, "weights")
        acc <> ", weights:[#{Enum.map_join(weights, ", ", &require_number!(&1, "weights"))}]"
    end
  end

  defp maybe_fuse_k(acc, opts) do
    case Keyword.fetch(opts, :k) do
      :error -> acc
      {:ok, k} -> acc <> ", k:#{require_pos_int!(k, "k")}"
    end
  end

  # Builds the ", {efSearch: :ef, …}" opts object + its params (only provided keys, in
  # `allowed` order). Values bind as params — never interpolated (probed). `allowed` is the
  # per-function allowlist passed by each caller (dense vs sparse), so this helper is shared:
  # `neighbors/6` and `sparse_neighbors/8` both route through it with their own allowlists.
  # (`fuse/3` builds its own opts via `fuse_opts/2` and does not route through here.)
  defp build_query_opts(opts, allowed) do
    Opts.validate_keys!(opts, allowed)

    {pairs, params} =
      Enum.reduce(allowed, {[], %{}}, fn key, {pairs, params} ->
        case Keyword.fetch(opts, key) do
          :error -> {pairs, params}
          {:ok, value} -> add_query_opt(key, value, pairs, params)
        end
      end)

    case Enum.reverse(pairs) do
      [] -> {"", %{}}
      list -> {", {#{Enum.join(list, ", ")}}", params}
    end
  end

  defp add_query_opt(:ef_search, value, pairs, params),
    do: {["efSearch: :ef" | pairs], Map.put(params, "ef", require_pos_int!(value, "ef_search"))}

  defp add_query_opt(:max_distance, value, pairs, params),
    do:
      {["maxDistance: :md" | pairs],
       Map.put(params, "md", require_number!(value, "max_distance"))}

  defp add_query_opt(:filter, value, pairs, params),
    do: {["filter: :rids" | pairs], Map.put(params, "rids", validate_rids!(value))}

  defp add_query_opt(:group_by, value, pairs, params),
    do: {["groupBy: :gb" | pairs], Map.put(params, "gb", validate_group_by!(value))}

  defp add_query_opt(:group_size, value, pairs, params),
    do: {["groupSize: :gs" | pairs], Map.put(params, "gs", require_pos_int!(value, "group_size"))}

  defp require_list!(v, _label) when is_list(v), do: v
  defp require_list!(_v, label), do: raise(ArgumentError, "#{label} must be a list of numbers")

  defp require_number!(v, _label) when is_number(v), do: v
  defp require_number!(_v, label), do: raise(ArgumentError, "#{label} must be a number")

  @rid_pattern ~r/\A#\d+:\d+\z/

  # A candidate-set filter must be a NON-EMPTY list of #<bucket>:<pos> RID strings. An empty
  # list is silently ignored by the server (returns everything) — fail loud. Value-free: the
  # offending RID is never echoed (Rule 3). Binds as a param; NOT an injection defense.
  defp validate_rids!([_ | _] = rids) do
    Enum.each(rids, fn
      rid when is_binary(rid) ->
        unless Regex.match?(@rid_pattern, rid) do
          raise ArgumentError, "filter must be a list of #<bucket>:<pos> RID strings"
        end

      _ ->
        raise ArgumentError, "filter must be a list of #<bucket>:<pos> RID strings"
    end)

    rids
  end

  defp validate_rids!([]),
    do: raise(ArgumentError, "filter must be a non-empty list of RIDs")

  defp validate_rids!(_),
    do: raise(ArgumentError, "filter must be a non-empty list of RIDs")

  # group_by is a property name bound as a PARAM value (injection closed by the param — probed:
  # a quote-breaking payload bound here is inert). Identifier.validate is a value-free client-side
  # SHAPE guard catching a typo/empty name (an unvalidated wrong name silently returns mis-shaped
  # rows) — NOT interpolation, NOT an injection defense.
  defp validate_group_by!(value) do
    case Identifier.validate(value) do
      :ok ->
        value

      {:error, :invalid_identifier} ->
        raise ArgumentError, "group_by must be a valid property identifier"
    end
  end

  defp build_metadata(dimensions, opts) do
    Opts.validate_keys!(opts, @index_opts)
    dims = require_pos_int!(dimensions, "dimensions")
    sim = enum!(@similarities, Keyword.get(opts, :similarity, :cosine), "similarity")
    mc = require_pos_int!(Keyword.get(opts, :max_connections, 16), "max_connections")
    bw = require_pos_int!(Keyword.get(opts, :beam_width, 100), "beam_width")

    "dimensions:#{dims}, similarity:'#{sim}', maxConnections:#{mc}, beamWidth:#{bw}"
    |> maybe_enum(opts, :encoding, @encodings, "encoding")
    |> maybe_enum(opts, :quantization, @quantizations, "quantization")
  end

  defp maybe_enum(acc, opts, key, allowed, label) do
    case Keyword.fetch(opts, key) do
      :error -> acc
      {:ok, value} -> acc <> ", #{camel(key)}:'#{enum!(allowed, value, label)}'"
    end
  end

  defp camel(:encoding), do: "encoding"
  defp camel(:quantization), do: "quantization"

  # dimensions (int) + modifier (NONE|IDF) — both optional; no METADATA clause when neither given.
  # KEY-allowlisted (server swallows unknown keys); modifier VALUE-allowlisted; source-verified
  # against LSMSparseVectorIndexMetadata.java.
  defp build_sparse_metadata(opts) do
    Opts.validate_keys!(opts, @sparse_index_opts)

    parts =
      []
      |> maybe_dimensions(opts)
      |> maybe_modifier(opts)

    case Enum.reverse(parts) do
      [] -> ""
      list -> " METADATA {#{Enum.join(list, ", ")}}"
    end
  end

  defp maybe_dimensions(parts, opts) do
    case Keyword.fetch(opts, :dimensions) do
      :error -> parts
      {:ok, value} -> ["dimensions:#{require_pos_int!(value, "dimensions")}" | parts]
    end
  end

  defp maybe_modifier(parts, opts) do
    case Keyword.fetch(opts, :modifier) do
      :error -> parts
      {:ok, value} -> ["modifier:'#{enum!(@sparse_modifiers, value, "modifier")}'" | parts]
    end
  end

  defp maybe_signal_preexisting([%{"totalIndexed" => n} | _]) when is_integer(n) and n > 0,
    do: Arcadic.Telemetry.event([:arcadic, :vector, :sparse_index_preexisting], %{count: n}, %{})

  defp maybe_signal_preexisting(_), do: :ok

  defp enum!(allowed, value, label) do
    case Map.fetch(allowed, value) do
      {:ok, str} -> str
      :error -> raise ArgumentError, "invalid #{label}; allowed: #{inspect(Map.keys(allowed))}"
    end
  end

  defp require_pos_int!(v, _label) when is_integer(v) and v > 0, do: v

  defp require_pos_int!(_v, label),
    do: raise(ArgumentError, "#{label} must be a positive integer")

  defp command_ok(conn, statement) do
    case Arcadic.command(conn, statement, %{}, language: "sql") do
      {:ok, _rows} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp bang(:ok), do: :ok
  defp bang({:ok, rows}), do: rows
  defp bang({:error, %{__exception__: true} = error}), do: raise(error)

  defp bang({:error, reason}),
    do: raise(ArgumentError, "vector operation failed: #{inspect(reason)}")
end
