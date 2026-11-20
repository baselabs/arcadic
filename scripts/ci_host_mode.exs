# Selects the dependency tree a consumer on this Elixir can run, before anything compiles.
#
# Run as `elixir scripts/ci_host_mode.exs` after `mix deps.get --check-locked`, with MIX_ENV
# set to the environment the job builds. For each dependency of that environment it walks the
# locked subtree (non-optional edges only, as a consumer resolves it) and reads every
# package's own Elixir requirement from its fetched Hex metadata:
#
#   * a required dependency whose subtree needs a newer Elixir fails the job: the lane sits
#     below the floor the dependency chain allows;
#   * an optional dependency whose subtree needs a newer Elixir is removed from this
#     disposable checkout's mix.exs, and the lock drops what nothing else uses, so the job
#     builds and tests the tree a host on this Elixir gets without that dependency.
#
# Nothing is compiled or loaded from the dependencies: a lane must test a host its Elixir can
# run, never a combination Mix accepts only with a requirement warning.

defmodule HostMode do
  def run do
    env = String.to_atom(System.get_env("MIX_ENV", "dev"))
    {:ok, project} = mix_project()

    {lock, _} =
      "mix.lock"
      |> File.read!()
      |> Code.string_to_quoted!(emit_warnings: false)
      |> Code.eval_quoted()

    elixir = System.version()

    deps =
      project
      |> Keyword.fetch!(:deps)
      |> Enum.map(&normalize/1)
      |> Enum.filter(fn {_app, opts} -> in_env?(opts, env) end)

    {optional, required} = Enum.split_with(deps, fn {_app, opts} -> opts[:optional] end)

    for {app, _} <- required, {pkg, req} <- unmet(app, lock, elixir) do
      fail(
        "required dependency #{app} needs #{pkg} (Elixir #{req}); Elixir #{elixir} is below that floor"
      )
    end

    dropped =
      for {app, _} <- optional, blockers = unmet(app, lock, elixir), blockers != [] do
        reasons = Enum.map_join(blockers, ", ", fn {pkg, req} -> "#{pkg} #{req}" end)

        IO.puts(
          :stderr,
          "Host mode: without optional #{app}; Elixir #{elixir} does not satisfy #{reasons}"
        )

        app
      end

    if dropped == [] do
      IO.puts(
        :stderr,
        "Host mode: every dependency for #{env}; Elixir #{elixir} satisfies each subtree"
      )
    else
      drop_from_mix_exs(dropped)

      {_, 0} =
        System.cmd("mix", ["deps.unlock", "--unused"], into: IO.stream(), stderr_to_stdout: true)
    end
  end

  defp mix_project do
    Mix.start()
    {:ok, Mix.Project.in_project(:host_project, ".", fn _ -> Mix.Project.config() end)}
  end

  defp normalize({app, opts}) when is_list(opts), do: {app, opts}
  defp normalize({app, _req}), do: {app, []}
  defp normalize({app, _req, opts}), do: {app, opts}

  defp in_env?(opts, env) do
    case Keyword.fetch(opts, :only) do
      :error -> true
      {:ok, only} -> env in List.wrap(only)
    end
  end

  # Every package in the app's non-optional locked subtree whose Elixir requirement this
  # Elixir does not satisfy, as {package, requirement}.
  defp unmet(app, lock, elixir) do
    app
    |> subtree(lock, MapSet.new())
    |> Enum.sort()
    |> Enum.flat_map(fn pkg ->
      case elixir_requirement(pkg) do
        nil -> []
        req -> if Version.match?(elixir, req), do: [], else: [{pkg, req}]
      end
    end)
  end

  defp subtree(app, lock, seen) do
    if MapSet.member?(seen, app) do
      seen
    else
      children =
        case Map.fetch(lock, app) do
          {:ok, {:hex, _pkg, _vsn, _hash, _managers, children, _repo, _outer}} ->
            children

          {:ok, other} ->
            fail(
              "#{app}: unsupported lock entry #{inspect(elem(other, 0))}; extend ci_host_mode.exs"
            )

          :error ->
            fail("#{app} is not in mix.lock")
        end

      children
      |> Enum.reject(fn {_child, _req, opts} -> opts[:optional] end)
      |> Enum.reduce(MapSet.put(seen, app), fn {child, _req, _opts}, acc ->
        subtree(child, lock, acc)
      end)
    end
  end

  # The requirement the package published (Hex metadata `elixir`); nil for a package with none,
  # such as an Erlang or rebar3 package.
  defp elixir_requirement(app) do
    path = Path.join(["deps", to_string(app), "hex_metadata.config"])

    case :file.consult(String.to_charlist(path)) do
      {:ok, terms} ->
        case List.keyfind(terms, "elixir", 0) do
          {"elixir", req} -> req
          nil -> nil
        end

      {:error, reason} ->
        fail("#{path}: #{inspect(reason)}; run mix deps.get --check-locked first")
    end
  end

  # Only this disposable CI checkout changes. The guards keep a reformat of mix.exs from
  # turning the removal into a silent no-op or a syntax error.
  defp drop_from_mix_exs(apps) do
    source = File.read!("mix.exs")

    stripped =
      Enum.reduce(apps, source, fn app, acc ->
        line = ~r/^[\t ]*\{:#{app},[^\n]*\n/m
        next = Regex.replace(line, acc, "")

        if next == acc or String.contains?(next, "{:#{app},") do
          fail(
            "could not remove the single-line {:#{app}, ...} entry from mix.exs; update ci_host_mode.exs"
          )
        end

        next
      end)

    case Code.string_to_quoted(stripped) do
      {:ok, _} ->
        File.write!("mix.exs", stripped)

      {:error, _} ->
        fail("removing #{inspect(apps)} broke mix.exs syntax; update ci_host_mode.exs")
    end
  end

  defp fail(message) do
    IO.puts(:stderr, "::error::#{message}")
    System.halt(1)
  end
end

HostMode.run()
