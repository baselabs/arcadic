# Run from an empty directory with mix run --no-mix-exs, using the pinned Hex archive.
if Mix.Project.get(), do: raise("docs archiving must run without a Mix project")

[directory, output] = System.argv()

unless File.regular?(Path.join(directory, "index.html")) do
  raise "docs must contain index.html"
end

# Match Hex 2.7.0's file listing, relative charlist paths, and version-name check.
files =
  "#{directory}/**"
  |> Path.wildcard()
  |> Enum.filter(&File.regular?/1)
  |> Enum.map(fn file ->
    relative = Path.relative_to(file, directory)
    top_level = relative |> Path.split() |> List.first()

    case Version.parse(top_level) do
      {:ok, _version} -> raise "top-level docs entries cannot match a semantic version"
      :error -> :ok
    end

    {String.to_charlist(relative), File.read!(file)}
  end)

{:ok, data} = :mix_hex_tarball.create_docs(files)
File.write!(output, data)
