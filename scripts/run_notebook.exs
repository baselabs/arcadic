# Runs one Livebook notebook top to bottom, the way Livebook evaluates it, against this
# checkout of Arcadic:
#
#     elixir scripts/run_notebook.exs notebooks/getting_started.livemd
#
# * Cells are the top-level ```elixir fences, in order. A fence that Livebook marks
#   `force_markdown` is prose, not a cell. A notebook with no cells fails.
# * The first cell must be the setup cell, holding the notebook's only `Mix.install/2`.
#   Its `:arcadic` dependency is rewritten to `path:` this checkout; other declared
#   dependencies use this checkout's mix.exs requirements. The notebook runs the code and
#   dependency set under test while its source describes the advertised Hex release.
#   A setup cell without exactly one `:arcadic` dependency fails.
# * Every other cell is evaluated with the bindings and the environment (aliases, imports,
#   requires) the cells before it left, as Livebook carries them, in one process, so a
#   `receive` sees messages sent to an earlier cell's caller.
#
# Connection values come from the environment variables each notebook already documents
# (`ARCADIC_HTTP_URL`, `ARCADIC_PASSWORD`, `ARCADIC_BOLT_HOST`, `ARCADIC_BOLT_PORT`).
# Each notebook needs its own OS process: `Mix.install/2` runs once per VM.

defmodule Arcadic.NotebookRunner do
  @checkout Path.expand("..", __DIR__)
  @app :arcadic

  def main([path]) do
    cells = path |> File.read!() |> cells(path)

    if cells == [] do
      fail(path, "has no elixir cells")
    end

    [{setup_line, setup} | rest] = cells
    Enum.each(rest, &refuse_install(path, &1))
    install(path, setup_line, setup)

    env = Code.env_for_eval(file: Path.expand(path))
    Enum.reduce(rest, {[], env}, &evaluate(path, &1, &2))

    IO.puts("#{path}: #{length(cells)} cells ok")
  end

  def main(_args) do
    IO.puts(:stderr, "usage: elixir scripts/run_notebook.exs NOTEBOOK.livemd")
    System.halt(2)
  end

  defp evaluate(path, {line, code}, {binding, env}) do
    quoted = Code.string_to_quoted!(code, file: path, line: line)

    try do
      {_value, binding, env} = Code.eval_quoted_with_env(quoted, binding, env)
      IO.puts("#{path}:#{line} ok")
      {binding, env}
    rescue
      error -> cell_failed(path, line, :error, error, __STACKTRACE__)
    catch
      kind, reason -> cell_failed(path, line, kind, reason, __STACKTRACE__)
    end
  end

  defp cell_failed(path, line, kind, reason, stacktrace) do
    fail(path, "cell at line #{line} failed:\n" <> Exception.format(kind, reason, stacktrace))
  end

  # Top-level fenced blocks only: Livebook cells never nest, so an indented or quoted fence
  # is prose. Returns `[{first_code_line, code}]` for every ```elixir fence that is not
  # marked force_markdown.
  defp cells(source, path) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> collect(path, :prose, false, [])
    |> Enum.reverse()
  end

  defp collect([], _path, :prose, _forced, acc), do: acc

  defp collect([], path, {_kind, first, _forced, _lines}, _, _acc) do
    fail(path, "has an unclosed fence opened before line #{first}")
  end

  defp collect([{text, line} | rest], path, :prose, forced, acc) do
    cond do
      force_markdown?(text) -> collect(rest, path, :prose, true, acc)
      fence?(text) -> collect(rest, path, {fence_kind(text), line + 1, forced, []}, false, acc)
      String.trim(text) == "" -> collect(rest, path, :prose, forced, acc)
      true -> collect(rest, path, :prose, false, acc)
    end
  end

  defp collect([{text, _line} | rest], path, {kind, first, forced, lines}, _, acc) do
    cond do
      String.trim_trailing(text) != "```" ->
        collect(rest, path, {kind, first, forced, [text | lines]}, false, acc)

      kind == "elixir" and not forced ->
        cell = {first, lines |> Enum.reverse() |> Enum.join("\n")}
        collect(rest, path, :prose, false, [cell | acc])

      true ->
        collect(rest, path, :prose, false, acc)
    end
  end

  defp force_markdown?(text) do
    String.starts_with?(text, "<!-- livebook:") and
      String.contains?(text, ~s("force_markdown":true))
  end

  defp fence?(text), do: String.starts_with?(text, "```")

  defp fence_kind(text), do: text |> String.trim_leading("`") |> String.trim()

  defp install(path, line, code) do
    quoted = rewrite_setup(path, line, code)
    Code.eval_quoted(quoted, [], file: path, line: line)
    IO.puts("#{path}:#{line} setup ok (#{@app} from #{@checkout})")
  end

  def rewrite_setup(path, line, code) do
    requirements = checkout_requirements()

    {quoted, counts} =
      code
      |> Code.string_to_quoted!(file: path, line: line)
      |> Macro.prewalk(%{install: 0, checkout: 0, requirements: requirements}, &rewrite_install/2)

    cond do
      counts.install != 1 ->
        fail(path, "the first cell must hold the notebook's Mix.install/2")

      counts.checkout != 1 ->
        fail(path, "the setup cell must install :#{@app} exactly once")

      true ->
        quoted
    end
  end

  # Reads the literal `defp deps` list from this checkout's mix.exs as source, so the project
  # module is defined only once, by Mix.install/2 loading the path dependency.
  defp checkout_requirements do
    mix_exs = Path.join(@checkout, "mix.exs")

    {_ast, deps} =
      mix_exs
      |> File.read!()
      |> Code.string_to_quoted!(file: mix_exs)
      |> Macro.prewalk(nil, fn
        {:defp, _, [{:deps, _, _}, [do: deps]]} = node, nil when is_list(deps) -> {node, deps}
        node, acc -> {node, acc}
      end)

    if deps == nil, do: fail(mix_exs, "has no literal `defp deps` list")

    Map.new(deps, fn
      {app, requirement} when is_atom(app) and is_binary(requirement) ->
        {app, requirement}

      {:{}, _, [app, requirement, _opts]} when is_atom(app) and is_binary(requirement) ->
        {app, requirement}

      dep ->
        fail(mix_exs, "declares #{Macro.to_string(dep)} without a literal version requirement")
    end)
  end

  defp rewrite_install({{:., _, [{:__aliases__, _, [:Mix]}, :install]}, _, _} = node, counts) do
    {call, meta, args} = node
    {args, checkout} = rewrite_args(args, counts.requirements)
    {{call, meta, args}, %{counts | install: counts.install + 1, checkout: checkout}}
  end

  defp rewrite_install(node, counts), do: {node, counts}

  defp rewrite_args([deps | opts], requirements) when is_list(deps) do
    {deps, checkout} = Enum.map_reduce(deps, 0, &rewrite_dep(&1, &2, requirements))
    {[deps | opts], checkout}
  end

  defp rewrite_args(args, _requirements), do: {args, 0}

  defp rewrite_dep({@app, _requirement}, n, _requirements),
    do: {{@app, [path: @checkout]}, n + 1}

  defp rewrite_dep({:{}, _, [@app | _]}, n, _requirements),
    do: {{@app, [path: @checkout]}, n + 1}

  defp rewrite_dep({app, _requirement} = dep, n, requirements) do
    case Map.fetch(requirements, app) do
      {:ok, requirement} -> {{app, requirement}, n}
      :error -> {dep, n}
    end
  end

  defp rewrite_dep({:{}, meta, [app, _requirement, opts]} = dep, n, requirements) do
    case Map.fetch(requirements, app) do
      {:ok, requirement} -> {{:{}, meta, [app, requirement, opts]}, n}
      :error -> {dep, n}
    end
  end

  defp rewrite_dep(dep, n, _requirements), do: {dep, n}

  defp refuse_install(path, {line, code}) do
    if code =~ ~r/\bMix\.install\b/ do
      fail(path, "calls Mix.install/2 outside the first cell (line #{line})")
    end
  end

  defp fail(path, message) do
    IO.puts(:stderr, "#{path}: #{message}")
    System.halt(1)
  end
end

Arcadic.NotebookRunner.main(System.argv())
