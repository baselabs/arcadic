# Checks consumer install tuples against the release advertised by mix.exs's version.
# Run with Elixir 1.18+ and network access; no fetched dependencies are needed.
# Only a Hex 404 selects the unpublished release's current mix.exs requirements.

defmodule InstallSnippets do
  @tuple ~r/\{\s*:([a-zA-Z_][a-zA-Z_0-9!?]*)\s*,\s*"([^"\n]*)"\s*(?=[,}])/

  def run do
    Mix.start()
    project = Mix.Project.in_project(:snippet_project, ".", fn _ -> Mix.Project.config() end)
    app = Keyword.fetch!(project, :app)
    version = Keyword.fetch!(project, :version)
    deps = requirements(Keyword.fetch!(project, :deps))
    {expected, source} = published_requirements(app, version, deps)
    %Version{major: major, minor: minor} = Version.parse!(version)
    expected = Map.put(expected, to_string(app), "~> #{major}.#{minor}")
    declared = MapSet.new([to_string(app) | Map.keys(deps)])

    mismatches =
      Enum.flat_map(files(), fn path ->
        path |> File.read!() |> mismatches(declared, expected, path, source)
      end)

    Enum.each(mismatches, &IO.puts(:stderr, &1))

    if mismatches != [] do
      System.halt(1)
    end

    IO.puts("Install snippets match #{source}")
  end

  def requirements(deps) do
    Map.new(deps, fn
      {app, requirement} when is_binary(requirement) -> {to_string(app), requirement}
      {app, requirement, _opts} when is_binary(requirement) -> {to_string(app), requirement}
      dep -> fail("mix.exs: #{elem(dep, 0)} must declare a version requirement")
    end)
  end

  # Scan prose and code alike, including inline tuples and multi-line dependency lists.
  # The declared-app allowlist excludes result tuples and unrelated example packages.
  def mismatches(text, declared, expected, path, source) do
    for [{offset, _}, app_span, requirement_span] <- Regex.scan(@tuple, text, return: :index),
        app = slice(text, app_span),
        MapSet.member?(declared, app),
        found = slice(text, requirement_span),
        wanted <- [Map.get(expected, app)],
        found != wanted do
      line = text |> binary_part(0, offset) |> String.split("\n") |> length()
      requirement = if wanted, do: inspect(wanted), else: "absent (not a published dependency)"

      "#{path}:#{line}: {:#{app}, #{inspect(found)}} must be #{requirement} (source: #{source})"
    end
  end

  defp slice(text, {offset, length}), do: binary_part(text, offset, length)

  defp files do
    ["README.md", "usage-rules.md"] ++
      Enum.flat_map(
        [
          "documentation/**/*.md",
          "livebooks/**/*.livemd",
          "notebooks/**/*.livemd",
          "lib/**/*.ex"
        ],
        &Path.wildcard/1
      )
  end

  defp published_requirements(app, version, deps) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)
    url = "https://hex.pm/api/packages/#{app}/releases/#{version}"

    options = [
      timeout: 30_000,
      connect_timeout: 10_000,
      autoredirect: false,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]

    case :httpc.request(
           :get,
           {String.to_charlist(url),
            [{~c"accept", ~c"application/json"}, {~c"user-agent", ~c"check_install_snippets"}]},
           options,
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _, body}} ->
        {decode_requirements(body, url, version), "Hex #{app} #{version}"}

      {:ok, {{_, 404, _}, _, _}} ->
        {deps, "mix.exs"}

      {:ok, {{_, status, _}, _, _}} ->
        fail("#{url}: HTTP #{status}; cannot verify install snippets")

      {:error, reason} ->
        fail("#{url}: #{inspect(reason)}; cannot verify install snippets")
    end
  end

  defp decode_requirements(body, url, version) do
    case JSON.decode(body) do
      {:ok, %{"version" => ^version, "requirements" => requirements}} when is_map(requirements) ->
        Map.new(requirements, fn
          {app, %{"requirement" => requirement}} when is_binary(requirement) ->
            {app, requirement}

          _ ->
            fail("#{url}: malformed dependency metadata; cannot verify install snippets")
        end)

      _ ->
        fail("#{url}: malformed release metadata; cannot verify install snippets")
    end
  end

  defp fail(message) do
    IO.puts(:stderr, "::error::#{message}")
    System.halt(1)
  end
end

InstallSnippets.run()
