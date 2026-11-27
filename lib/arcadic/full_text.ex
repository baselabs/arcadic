defmodule Arcadic.FullText do
  @moduledoc """
  ArcadeDB full-text search — tenant-blind `FULL_TEXT` (Lucene) index DDL and
  `SEARCH_INDEX`/`SEARCH_FIELDS` query builders, parallel to `Arcadic.Vector`.

  The query text and candidate RID list bind as the SQL parameters `:q` and `:rids`.
  The index reference `"Type[property]"` and analyzer class name are interpolated only
  after identifier and dotted-class-name validation. A `FULL_TEXT` index **retro-indexes rows
  that already exist** when it is created (unlike `LSM_SPARSE_VECTOR`, which does not) — so there is
  no create-before-load ordering requirement. Full-text is HTTP-only SQL (Bolt is Cypher-only).

  `search/5`'s `property_or_properties` must match an existing FULL_TEXT index by NAME: a
  single-property index is `Type[prop]`, a composite `create_index(conn, T, [a, b])` is `Type[a,b]`
  (search it with the same list). `SEARCH_INDEX` on a ref with no matching index is a server
  `SchemaException`. `search_fields/5` names the fields directly and needs no exact index-name match.
  Both searches accept a `:filter` list of candidate RIDs. An empty candidate set returns
  `{:ok, []}` without a request.
  """
  alias Arcadic.{Conn, Identifier, Opts, RidFilter}

  @create_opts [:if_not_exists, :analyzer]
  @search_opts [:limit, :with_score, :filter]

  # Friendly atom → Lucene analyzer FQCN. The validated-FQCN-string path (below) covers any analyzer,
  # so this map is convenience, not a ceiling.
  @analyzers %{
    standard: "org.apache.lucene.analysis.standard.StandardAnalyzer",
    english: "org.apache.lucene.analysis.en.EnglishAnalyzer",
    keyword: "org.apache.lucene.analysis.core.KeywordAnalyzer",
    whitespace: "org.apache.lucene.analysis.core.WhitespaceAnalyzer",
    simple: "org.apache.lucene.analysis.core.SimpleAnalyzer"
  }
  # A dotted Java FQCN, quote/space/control-free — injection-inert inside the single-quoted literal.
  @analyzer_fqcn ~r/\A[A-Za-z][A-Za-z0-9_.]*\z/

  @doc """
  Creates a `FULL_TEXT` index on `type` over one property or a list of properties (idempotent —
  `IF NOT EXISTS` unless `if_not_exists: false`). `opts`: `:if_not_exists` (bool, default true),
  `:analyzer` (a friendly atom — `:standard`/`:english`/`:keyword`/`:whitespace`/`:simple` — or a
  Lucene FQCN string). Retro-indexes existing rows. Value-free on a bad identifier / analyzer / opt.
  """
  @spec create_index(Conn.t(), String.t(), String.t() | [String.t()], keyword()) ::
          :ok | {:error, atom() | Exception.t()}
  def create_index(conn, type, property_or_properties, opts \\ [])

  def create_index(conn, _, _, _) when not is_struct(conn, Conn),
    do: raise(ArgumentError, "expected an Arcadic.Conn as the first argument")

  def create_index(%Conn{} = conn, type, property_or_properties, opts) do
    Opts.validate_keys!(opts, @create_opts)

    with {:ok, ident_list} <- validate_type_and_props(type, property_or_properties) do
      guard = if Keyword.get(opts, :if_not_exists, true), do: " IF NOT EXISTS", else: ""
      metadata = analyzer_metadata(opts)
      cols = Enum.join(ident_list, ", ")
      command_ok(conn, "CREATE INDEX#{guard} ON #{type} (#{cols}) FULL_TEXT#{metadata}")
    end
  end

  def create_index!(conn, type, property_or_properties, opts \\ [])

  def create_index!(conn, _, _, _) when not is_struct(conn, Conn),
    do: raise(ArgumentError, "expected an Arcadic.Conn as the first argument")

  @doc "Creates a FULL_TEXT index, raising on error."
  @spec create_index!(Conn.t(), String.t(), String.t() | [String.t()], keyword()) :: :ok
  def create_index!(%Conn{} = conn, type, property_or_properties, opts),
    do: bang(create_index(conn, type, property_or_properties, opts))

  @doc "Drops a FULL_TEXT index (idempotent — `IF EXISTS`)."
  @spec drop_index(Conn.t(), String.t(), String.t() | [String.t()]) ::
          :ok | {:error, atom() | Exception.t()}
  def drop_index(conn, _, _) when not is_struct(conn, Conn),
    do: raise(ArgumentError, "expected an Arcadic.Conn as the first argument")

  def drop_index(%Conn{} = conn, type, property_or_properties) do
    with {:ok, ref} <- index_ref(type, property_or_properties) do
      command_ok(conn, "DROP INDEX `#{ref}` IF EXISTS")
    end
  end

  def drop_index!(conn, _, _) when not is_struct(conn, Conn),
    do: raise(ArgumentError, "expected an Arcadic.Conn as the first argument")

  @doc "Drops a FULL_TEXT index, raising on error."
  @spec drop_index!(Conn.t(), String.t(), String.t() | [String.t()]) :: :ok
  def drop_index!(%Conn{} = conn, type, property_or_properties),
    do: bang(drop_index(conn, type, property_or_properties))

  @doc """
  Searches a full-text index via `SEARCH_INDEX('Type[property]', :q)` and returns
  whole records ranked by relevance. `query` binds as `:q`. Set `:limit` to a
  positive integer to cap the result, or set `:with_score` to include the BM25
  score in a `"score"` field. Use `:filter` to restrict matches to a list of
  `#<bucket>:<pos>` RID strings, bound as `:rids`. An empty list returns no rows.
  """
  @spec search(Conn.t(), String.t(), String.t() | [String.t()], String.t(), keyword()) ::
          {:ok, [map()]} | {:error, atom() | Exception.t()}
  def search(conn, type, property_or_properties, query, opts \\ [])

  def search(conn, _, _, _, _) when not is_struct(conn, Conn),
    do: raise(ArgumentError, "expected an Arcadic.Conn as the first argument")

  def search(%Conn{} = conn, type, property_or_properties, query, opts) do
    unless is_binary(query), do: raise(ArgumentError, "query must be a string")
    Opts.validate_keys!(opts, @search_opts)

    with {:ok, ref} <- index_ref(type, property_or_properties) do
      run_search(conn, type, "SEARCH_INDEX('#{ref}', :q) = true", query, opts)
    end
  end

  def search!(conn, type, property_or_properties, query, opts \\ [])

  def search!(conn, _, _, _, _) when not is_struct(conn, Conn),
    do: raise(ArgumentError, "expected an Arcadic.Conn as the first argument")

  @doc "Full-text `search`, returning rows or raising."
  @spec search!(Conn.t(), String.t(), String.t() | [String.t()], String.t(), keyword()) :: [map()]
  def search!(%Conn{} = conn, type, property_or_properties, query, opts),
    do: bang(search(conn, type, property_or_properties, query, opts))

  @doc """
  Searches FULL_TEXT-indexed fields via `SEARCH_FIELDS(['p1','p2'…], :q)` and returns
  whole records. Accepts the same options, including the candidate RID `:filter`, as
  `search/5`. Setting `:with_score` projects a constant `score: 0.0` on every row.
  Use `search/5` for the BM25 score.
  """
  @spec search_fields(Conn.t(), String.t(), [String.t()], String.t(), keyword()) ::
          {:ok, [map()]} | {:error, atom() | Exception.t()}
  def search_fields(conn, type, properties, query, opts \\ [])

  def search_fields(conn, _, _, _, _) when not is_struct(conn, Conn),
    do: raise(ArgumentError, "expected an Arcadic.Conn as the first argument")

  def search_fields(%Conn{} = conn, type, properties, query, opts) when is_list(properties) do
    Opts.validate_keys!(opts, @search_opts)

    with {:ok, props} <- validate_type_and_props(type, properties) do
      field_list = Enum.map_join(props, ", ", &"'#{&1}'")
      run_search(conn, type, "SEARCH_FIELDS([#{field_list}], :q) = true", query, opts)
    end
  end

  # Total value-free fallback: a non-list `properties` (e.g. a bare string) must NOT fall through
  # to a FunctionClauseError, whose blame rendering echoes every arg — including `query` (Rule 3).
  def search_fields(%Conn{} = _conn, _type, _properties, _query, _opts) do
    raise ArgumentError, "properties must be a list of property names"
  end

  def search_fields!(conn, type, properties, query, opts \\ [])

  def search_fields!(conn, _, _, _, _) when not is_struct(conn, Conn),
    do: raise(ArgumentError, "expected an Arcadic.Conn as the first argument")

  @doc "Full-text `search_fields`, returning rows or raising."
  @spec search_fields!(Conn.t(), String.t(), [String.t()], String.t(), keyword()) :: [map()]
  def search_fields!(%Conn{} = conn, type, properties, query, opts),
    do: bang(search_fields(conn, type, properties, query, opts))

  @doc """
  Builds the FULL_TEXT index reference `"Type[p1,p2]"`. Accepts one property or a
  non-empty list in index order and validates every identifier.
  """
  @spec index_ref(String.t(), String.t() | [String.t()]) ::
          {:ok, String.t()} | {:error, :invalid_identifier}
  def index_ref(type, property_or_properties) do
    with {:ok, props} <- validate_type_and_props(type, property_or_properties) do
      {:ok, "#{type}[#{Enum.join(props, ",")}]"}
    end
  end

  # --- private ---

  # Empty property lists would produce server-rejected DDL, index refs, or SEARCH_FIELDS calls.
  defp require_props!(property_or_properties) do
    case List.wrap(property_or_properties) do
      [] -> raise ArgumentError, "at least one property is required"
      props -> props
    end
  end

  defp validate_type_and_props(type, property_or_properties) do
    props = require_props!(property_or_properties)

    with :ok <- Identifier.validate(type),
         :ok <- validate_each(props) do
      {:ok, props}
    end
  end

  defp validate_each([]), do: :ok

  defp validate_each([ident | rest]) do
    with :ok <- Identifier.validate(ident) do
      validate_each(rest)
    end
  end

  defp validate_each(_), do: {:error, :invalid_identifier}

  defp run_search(conn, type, predicate, query, opts) do
    {limit, params} = limit_fragment(opts, %{"q" => query})

    case Keyword.fetch(opts, :filter) do
      {:ok, []} ->
        {:ok, []}

      filter ->
        {rid_predicate, params} = filter_fragment(filter, params)
        proj = score_projection(opts)
        sql = "SELECT #{proj}FROM #{type} WHERE #{predicate}#{rid_predicate}#{limit}"
        Arcadic.query(conn, sql, params, language: "sql")
    end
  end

  defp filter_fragment(:error, params), do: {"", params}

  defp filter_fragment({:ok, rids}, params),
    do: {" AND @rid IN :rids", Map.put(params, "rids", RidFilter.validate!(rids))}

  # The $score projection when :with_score, "" otherwise. SEARCH_INDEX stays two-argument: the
  # server ranks by relevance without ORDER BY (so no synthetic-alias column), and 26.12 rejects
  # a third options argument (see AGENTS.md drift notes).
  defp score_projection(opts) do
    if Keyword.get(opts, :with_score, false), do: "*, $score AS score ", else: ""
  end

  defp limit_fragment(opts, params) do
    case Keyword.fetch(opts, :limit) do
      :error -> {"", params}
      {:ok, k} when is_integer(k) and k > 0 -> {" LIMIT :k", Map.put(params, "k", k)}
      {:ok, _} -> raise ArgumentError, "limit must be a positive integer"
    end
  end

  defp analyzer_metadata(opts) do
    case Keyword.fetch(opts, :analyzer) do
      :error -> ""
      {:ok, a} -> " METADATA {analyzer:'#{analyzer_fqcn!(a)}'}"
    end
  end

  defp analyzer_fqcn!(a) when is_atom(a) do
    case Map.fetch(@analyzers, a) do
      {:ok, fqcn} ->
        fqcn

      :error ->
        raise ArgumentError, "unknown analyzer; known atoms: #{inspect(Map.keys(@analyzers))}"
    end
  end

  defp analyzer_fqcn!(a) when is_binary(a) do
    if Regex.match?(@analyzer_fqcn, a),
      do: a,
      else: raise(ArgumentError, "analyzer must be a dotted Lucene class name")
  end

  defp analyzer_fqcn!(_),
    do: raise(ArgumentError, "analyzer must be an atom or a class-name string")

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
    do: raise(ArgumentError, "full-text operation failed: #{inspect(reason)}")
end
