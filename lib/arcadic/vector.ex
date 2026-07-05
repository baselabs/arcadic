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
  alias Arcadic.{Conn, Identifier}

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

  @query_opts [:ef_search, :max_distance]

  @doc """
  Runs a dense nearest-neighbour search, returning rows ranked closest-first (each
  carries the vertex's top-level fields plus `distance`). `query_vector` and `k` bind
  as params. `opts`: `ef_search` (pos_integer), `max_distance` (number) — both bind as
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
      {opt_obj, opt_params} = build_query_opts(opts)
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

  @fusions %{rrf: "RRF", dbsf: "DBSF", linear: "LINEAR"}
  @fuse_opts [:fusion, :weights, :k]

  @doc """
  Runs a hybrid fusion over dense neighbour subqueries. `neighbor_specs` is a non-empty
  list of `{type, property, query_vector, k}`, each built as a validated `vector.neighbors`
  subquery with distinct indexed params. `opts`: `fusion` (`:rrf` default | `:dbsf` |
  `:linear`), `weights` (list of numbers), `k` (pos_integer).

  Fused rows are ranked by ArcadeDB's fusion `score` (higher = better) rather than the
  `distance` that `neighbors/6` returns.

  `neighbor_specs` and `weights` are trusted developer-supplied config: the emitted
  statement grows linearly with their length (no cap), matching arcadic's
  no-statement-size-limit posture elsewhere.
  """
  @spec fuse(Conn.t(), [{String.t(), String.t(), [number()], pos_integer()}], keyword()) ::
          {:ok, [map()]} | {:error, atom() | Exception.t()}
  def fuse(%Conn{} = conn, neighbor_specs, opts \\ []) do
    validate_opt_keys!(opts, @fuse_opts)
    fusion = enum!(@fusions, Keyword.get(opts, :fusion, :rrf), "fusion")

    with {:ok, subqueries, params} <- build_subqueries(neighbor_specs) do
      sql =
        "SELECT expand(vector.fuse(#{Enum.join(subqueries, ", ")}, {#{fuse_opts(fusion, opts)}}))"

      Arcadic.query(conn, sql, params, language: "sql")
    end
  end

  @doc "Runs a hybrid fusion, returning rows or raising."
  @spec fuse!(Conn.t(), [{String.t(), String.t(), [number()], pos_integer()}], keyword()) :: [
          map()
        ]
  def fuse!(%Conn{} = conn, neighbor_specs, opts \\ []),
    do: bang(fuse(conn, neighbor_specs, opts))

  # --- private ---

  defp build_subqueries(specs) when is_list(specs) and specs != [] do
    specs
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], %{}}, fn {spec, i}, {:ok, subs, params} ->
      {type, property, vec, k} = require_spec!(spec)

      case index_ref(type, property) do
        {:ok, ref} ->
          k = require_pos_int!(k, "k")
          vec = require_list!(vec, "query_vector")
          sub = "(SELECT expand(vector.neighbors('#{ref}', :vec#{i}, :k#{i})))"
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

  defp build_subqueries(_specs) do
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

  # Builds the ", {efSearch: :ef, maxDistance: :md}" opts object + its params (only
  # provided keys). Values bind as params — never interpolated (probed).
  defp build_query_opts(opts) do
    validate_opt_keys!(opts, @query_opts)

    {pairs, params} =
      Enum.reduce(@query_opts, {[], %{}}, fn key, {pairs, params} ->
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

  defp require_list!(v, _label) when is_list(v), do: v
  defp require_list!(_v, label), do: raise(ArgumentError, "#{label} must be a list of numbers")

  defp require_number!(v, _label) when is_number(v), do: v
  defp require_number!(_v, label), do: raise(ArgumentError, "#{label} must be a number")

  defp build_metadata(dimensions, opts) do
    validate_opt_keys!(opts, @index_opts)
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

  defp validate_opt_keys!(opts, allowed) do
    # Guard the shape BEFORE Keyword.keys/1. On an improper keyword list (a non-atom key
    # or a non-tuple element) Keyword.keys/1 raises a message that ECHOES the offending
    # entry — a Rule-3 caller-value leak; on a non-list it raises a FunctionClauseError.
    # Keyword.keyword?/1 is value-free and false for maps/atoms/improper lists.
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "opts must be a keyword list"
    end

    case Keyword.keys(opts) -- allowed do
      [] ->
        :ok

      bad ->
        raise ArgumentError, "unknown option(s) #{inspect(bad)}; allowed: #{inspect(allowed)}"
    end
  end

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
