# Shared by qualification and publication. The declared package files exclude
# development paths; documentation/ and notebooks remain legitimate package content.
[package, metadata_path] = System.argv()
version = System.fetch_env!("VERSION")

files =
  package
  |> Path.join("**/*")
  |> Path.wildcard(match_dot: true)
  |> Enum.reject(&File.dir?/1)
  |> Enum.map(&Path.relative_to(&1, package))
  |> Enum.sort()

Enum.each(files, &IO.puts/1)

missing = ~w(mix.exs README.md LICENSE CHANGELOG.md) -- files

forbidden =
  Enum.filter(files, fn file ->
    [root | _] = Path.split(file)

    root in ~w(test .github docs scripts) or
      Enum.any?(Path.split(file), &String.starts_with?(&1, ".env"))
  end)

if missing != [] or forbidden != [] do
  raise "Package inspection failed: missing #{inspect(missing)}, forbidden #{inspect(forbidden)}"
end

metadata_file = String.to_charlist(metadata_path)
{:ok, metadata} = :file.consult(metadata_file)
actual = Map.new(metadata)["version"]

if actual != version do
  raise "Package version mismatch: expected #{version}, metadata #{inspect(actual)}"
end

IO.puts("Package inspection passed for version #{version}")
