# Run from a directory without mix.exs. Only Hex and the inspected bytes are loaded.
defmodule Release.UploadHex do
  @moduledoc false

  def main([name, version, package, docs]) do
    if Mix.Project.get(), do: raise("publication must run without a Mix project")

    package_bytes = File.read!(package)
    docs_bytes = File.read!(docs)
    key = System.get_env("HEX_API_KEY")

    if not is_binary(key) or String.trim(key) == "" do
      raise "HEX_API_KEY is required; publication stopped"
    end

    Hex.start()
    auth = [key: key]
    existing_package!(lookup(fn -> Hex.API.Package.get(nil, name, auth) end), name)
    digest = :crypto.hash(:sha256, package_bytes) |> Base.encode16(case: :lower)

    has_docs =
      case lookup(fn -> Hex.API.Release.get(nil, name, version, auth) end) do
        {:ok, {404, _headers, _body}} ->
          accepted!(
            Hex.API.Release.publish(nil, package_bytes, auth, fn _ -> nil end, replace: false),
            "Package"
          )

          false

        {:ok, {200, _headers, body}} when is_map(body) ->
          existing_release!(body, digest)

        _result ->
          raise "Hex release lookup failed; publication refused"
      end

    unless has_docs do
      accepted!(
        Hex.API.ReleaseDocs.publish(nil, name, version, docs_bytes, auth, fn _ -> nil end),
        "Docs"
      )
    end
  end

  def main(_argv), do: raise("usage: upload_hex.exs NAME VERSION PACKAGE DOCS")

  # Read retries cannot create or replace a release. Ambiguous writes stop for redispatch.
  defp lookup(fun, attempts \\ 3) do
    case fun.() do
      {:ok, {code, _headers, _body}} when code in 500..599 and attempts > 1 ->
        Process.sleep(2_000)
        lookup(fun, attempts - 1)

      result ->
        result
    end
  end

  defp existing_package!({:ok, {200, _headers, _body}}, _name), do: :ok

  defp existing_package!({:ok, {404, _headers, _body}}, name),
    do: raise("the name #{name} is not on Hex; a first publication is the owner's decision")

  defp existing_package!(_result, _name),
    do: raise("Hex package lookup failed; publication refused")

  defp existing_release!(body, digest) do
    unless Map.has_key?(body, "retirement") and is_nil(body["retirement"]) do
      raise "Hex release is retired or its retirement state is unknown; publication refused"
    end

    if body["checksum"] != digest do
      raise "Hex package checksum differs from inspected bytes; publication refused"
    end

    case body["has_docs"] do
      present when is_boolean(present) -> present
      _other -> raise "Hex docs state is unknown; publication refused"
    end
  end

  defp accepted!({:ok, {code, _headers, %{"status" => "staged"}}}, _label) when code in 200..299 do
    raise "held for approval on hex.pm; approve it, then dispatch again on the same commit"
  end

  defp accepted!({:ok, {code, _headers, _body}}, label) when code in 200..299,
    do: IO.puts("#{label}: archive accepted")

  defp accepted!(_result, label),
    do: raise("#{label} upload failed or ambiguous; dispatch again on the same commit")
end

Release.UploadHex.main(System.argv())
