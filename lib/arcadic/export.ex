defmodule Arcadic.Export do
  @moduledoc """
  Server-side database export over ArcadeDB's `EXPORT DATABASE file://<name>` command (symmetric to
  `Arcadic.Import`). The target is a bare `<name>` written to the server's configured exports
  directory — a path/traversal character is rejected value-free (ArcadeDB itself rejects a directory
  in the target: "Export file cannot contain path change"). `with:` settings (e.g. `format: "jsonl"`,
  `overwrite: true`) reuse `Arcadic.Import`'s no-parens grammar: names `Arcadic.Identifier`-validated,
  values number/boolean/string (string values charset-allowlisted, injection-inert). Tenant-blind;
  every rejection is value-free (never echoes the name/value — AGENTS.md Rule 3). The success row
  (`operation`/`toUrl`/`totalRecords`/…) is top-level-`@props`-stripped by `Result.normalize` (a
  shallow `Map.drop` per row — correct because the export row is flat) via `command/4`.
  """
  alias Arcadic.{Conn, Import, Opts}

  # A bare export filename: alphanumerics + `-` `_` `~` only — NO `/` `.` `:` `%` `'` `\`, so no
  # directory, traversal, quote, or escape. ArcadeDB writes to its own exports dir; arcadic supplies
  # only the leaf name (probe-verified it rejects `../etc/passwd`, `a/b`, `a'b`, `a\b`).
  @name_pattern ~r/\A[A-Za-z0-9\-_~]+\z/

  @doc """
  Exports `conn.database` to `file://<name>` server-side. Returns `{:ok, rows}` (rows carry
  `operation`/`toUrl`/`totalRecords`/`documents`/`vertices`/`result`) or
  `{:error, Arcadic.Error.t() | Arcadic.TransportError.t()}`.

  `opts`: `with` — a keyword list of export settings (`format:`, `overwrite:`, …), same rules as
  `Arcadic.Import`. Raises `ArgumentError` (value-free) on a bad name or `with:` entry.
  """
  @spec database(Conn.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, Exception.t()}
  def database(%Conn{} = conn, name, opts \\ []) do
    validate_name!(name)
    Opts.validate_keys!(opts, [:with])
    with_clause = Import.build_with(Keyword.get(opts, :with, []))
    Arcadic.command(conn, "EXPORT DATABASE file://#{name}#{with_clause}", %{}, language: "sql")
  end

  @doc "Exports `conn.database`, returning the rows or raising."
  @spec database!(Conn.t(), String.t(), keyword()) :: [map()]
  def database!(%Conn{} = conn, name, opts \\ []), do: bang(database(conn, name, opts))

  defp validate_name!(name) when is_binary(name) do
    if Regex.match?(@name_pattern, name),
      do: :ok,
      else:
        raise(ArgumentError, "export name has characters outside the allowed set (no path/quote)")
  end

  defp validate_name!(_), do: raise(ArgumentError, "export name must be a string")

  defp bang({:ok, rows}), do: rows
  defp bang({:error, %{__exception__: true} = error}), do: raise(error)
end
