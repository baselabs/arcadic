# Selects the tests the quick workflow runs for a branch: every changed test file, plus every
# test file that names a module defined in a changed library file or in a library file that
# depends on one directly. A change to the build itself (mix.exs, mix.lock, .tool-versions,
# config, the test helper or test support) selects the whole suite, because every test
# depends on it.
#
#   elixir scripts/quick_tests.exs BASE_REF
#
# Prints one line: `all`, `none`, or the selected test files separated by spaces.
# Run it from the repository root after `mix deps.get`; it calls `git` and `mix xref`.

defmodule QuickTests do
  @whole_suite ~r{\A(mix\.exs|mix\.lock|\.tool-versions|config/.*|test/test_helper\.exs|test/support/.*)\z}

  def main([base]) do
    changed = changed_files(base)

    cond do
      Enum.any?(changed, &Regex.match?(@whole_suite, &1)) -> IO.puts("all")
      (selected = select(changed)) == [] -> IO.puts("none")
      true -> IO.puts(Enum.join(selected, " "))
    end
  end

  def main(_) do
    IO.puts(:stderr, "usage: elixir scripts/quick_tests.exs BASE_REF")
    System.halt(2)
  end

  defp changed_files(base) do
    merge_base = git!(["merge-base", base, "HEAD"]) |> String.trim()

    git!(["diff", "--name-only", "--diff-filter=d", merge_base, "HEAD"])
    |> String.split("\n", trim: true)
  end

  defp select(changed) do
    tests = Path.wildcard("test/**/*_test.exs")
    changed_tests = Enum.filter(changed, &(&1 in tests))
    lib = Enum.filter(changed, &String.match?(&1, ~r{\Alib/.*\.exs?\z}))
    lib = Enum.uniq(lib ++ direct_dependents(lib))
    modules = Enum.flat_map(lib, &defined_modules/1)

    referencing =
      Enum.filter(tests, fn test ->
        source = File.read!(test)
        Enum.any?(lib, &(mirror(&1) == test)) or Enum.any?(modules, &names?(source, &1))
      end)

    Enum.sort(Enum.uniq(changed_tests ++ referencing))
  end

  # Library files with a direct compile, export or runtime edge to a changed file.
  defp direct_dependents([]), do: []

  defp direct_dependents(files) do
    sinks = Enum.flat_map(files, &["--sink", &1])

    {out, 0} =
      System.cmd("mix", ["xref", "graph", "--only-direct", "--format", "plain" | sinks],
        stderr_to_stdout: true
      )

    Regex.scan(~r{\blib/[\w/.-]+\.exs?\b}, out) |> List.flatten() |> Enum.uniq()
  end

  defp defined_modules(file) do
    Regex.scan(~r/^\s*defmodule\s+([A-Z][\w.]*)/m, File.read!(file), capture: :all_but_first)
    |> List.flatten()
  end

  # lib/a/b.ex is covered by test/a/b_test.exs when that file exists.
  defp mirror(lib_file) do
    lib_file
    |> String.replace_prefix("lib/", "test/")
    |> String.replace(~r/\.exs?\z/, "_test.exs")
  end

  # The full name, or its last segment inside a multi-alias of its parent
  # (`alias Parent.{Child, Other}`).
  defp names?(source, module) do
    String.contains?(source, module) or
      case String.split(module, ".") do
        [_single] ->
          false

        parts ->
          {parent, [last]} = Enum.split(parts, -1)
          parent = Regex.escape(Enum.join(parent, "."))
          Regex.match?(~r/#{parent}\.\{[^}]*\b#{Regex.escape(last)}\b/s, source)
      end
  end

  defp git!(args) do
    {out, 0} = System.cmd("git", args)
    out
  end
end

QuickTests.main(System.argv())
