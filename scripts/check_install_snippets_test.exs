# Pure scanner and notebook-rewrite checks; no service is substituted or contacted.
ExUnit.start()

for script <- ["check_install_snippets.exs", "run_notebook.exs"] do
  {:__block__, _, [module, _entrypoint]} =
    __DIR__ |> Path.join(script) |> File.read!() |> Code.string_to_quoted!()

  Code.compile_quoted(module, Path.join(__DIR__, script))
end

defmodule InstallSnippetsTest do
  use ExUnit.Case, async: false

  test "requirements include optional and environment-specific dependencies" do
    assert InstallSnippets.requirements([
             {:runtime_dep, "~> 1.0"},
             {:optional_dep, "~> 2.0", optional: true},
             {:dev_dep, "~> 3.0", only: :dev}
           ]) == %{
             "runtime_dep" => "~> 1.0",
             "optional_dep" => "~> 2.0",
             "dev_dep" => "~> 3.0"
           }
  end

  test "every mismatch has a byte-correct line, requirement and release source" do
    text = """
    π inline `{:library, "~> 0.1"}` and `{:dependency, "~> 0.2", optional: true}`
    {:dependency,
      "~> 0.3"}
    {:dependency, "~> 2.0"}
    {:unrelated, "~> 9.0"}
    {:ok, "a result"}
    """

    assert InstallSnippets.mismatches(
             text,
             MapSet.new(["library", "dependency"]),
             %{"library" => "~> 1.0", "dependency" => "~> 2.0"},
             "README.md",
             "Hex library 1.0.0"
           ) == [
             ~s|README.md:1: {:library, "~> 0.1"} must be "~> 1.0" (source: Hex library 1.0.0)|,
             ~s|README.md:1: {:dependency, "~> 0.2"} must be "~> 2.0" (source: Hex library 1.0.0)|,
             ~s|README.md:2: {:dependency, "~> 0.3"} must be "~> 2.0" (source: Hex library 1.0.0)|
           ]
  end

  test "unpublished requirements and dependencies absent from a release fail closed" do
    assert InstallSnippets.mismatches(
             ~s|{:dependency, "~> 1.0"}|,
             MapSet.new(["dependency"]),
             %{"dependency" => "~> 2.0"},
             "lib/example.ex",
             "mix.exs"
           ) == [
             ~s|lib/example.ex:1: {:dependency, "~> 1.0"} must be "~> 2.0" (source: mix.exs)|
           ]

    assert [message] =
             InstallSnippets.mismatches(
               ~s|{:dev_dep, "~> 1.0"}|,
               MapSet.new(["dev_dep"]),
               %{},
               "README.md",
               "Hex library 1.0.0"
             )

    assert message =~ "not a published dependency"
  end

  test "notebook setup uses every checkout requirement and preserves unrelated dependencies" do
    Mix.start()
    project = Mix.Project.in_project(:notebook_project, ".", fn _ -> Mix.Project.config() end)
    app = Keyword.fetch!(project, :app)
    runner = Module.concat([project[:name], "NotebookRunner"])

    requirements = Map.new(project[:deps], fn dep -> {elem(dep, 0), elem(dep, 1)} end)

    for self <- [{app, "~> 0.0"}, {app, "~> 0.0", runtime: false}] do
      dependencies =
        Enum.flat_map(requirements, fn {dep, _requirement} ->
          [{dep, "~> 0.0"}, {dep, "~> 0.0", runtime: false}]
        end)

      deps = [self, {:consumer_snippet_unrelated, "~> 9.0"} | dependencies]
      code = "Mix.install(#{inspect(deps, limit: :infinity)}, consolidate_protocols: false)"
      quoted = runner.rewrite_setup("notebook.livemd", 1, code)
      {{:., _, _}, _, [rewritten, opts]} = quoted

      assert [{^app, [path: checkout]}, {:consumer_snippet_unrelated, "~> 9.0"} | rewritten] =
               rewritten

      assert checkout == Path.expand("..", __DIR__)
      assert opts == [consolidate_protocols: false]

      Enum.each(Enum.chunk_every(rewritten, 2), fn pair ->
        assert [{dep, requirement}, {:{}, _, [dep, requirement, options]}] = pair
        assert requirement == Map.fetch!(requirements, dep)
        assert options == [runtime: false]
      end)

      assert length(rewritten) == 2 * map_size(requirements)
    end
  end
end
