defmodule Arcadic.Result do
  @moduledoc """
  Normalizes an ArcadeDB command/query response envelope into a list of rows.

  Strips `@props` (serializer noise on projection rows) but KEEPS the record and
  graph identity keys the data layer needs: `@rid`, `@type`, `@cat` (`"v"`/`"e"`),
  `@in`, `@out` (edges only). Probe-verified — spec §15 P4/P5/P15.

  An EXPLAIN/PROFILE envelope carries its plan under `explainPlan` (never `result`),
  so `normalize/1` returns `{:error, %Arcadic.Error{reason: :use_explain}}` for it
  rather than a silent empty row set. The plan surface is `normalize_plan/1`,
  consumed by `Arcadic.explain/4` and `Arcadic.profile/4`.
  """

  @stripped_keys ~w(@props)

  @doc """
  Extract `result`, strip `@props` per row; return `{:ok, rows}`.

  ## Examples

      iex> Arcadic.Result.normalize(%{"result" => [%{"n" => 1, "@props" => "n:1"}]})
      {:ok, [%{"n" => 1}]}

  """
  @spec normalize(map()) :: {:ok, [map()]} | {:error, Arcadic.Error.t()}
  # A plan envelope (EXPLAIN/PROFILE) carries a top-level `explainPlan` key and an empty
  # (or executed-rows) `result`. It cannot be represented as `{:ok, rows}` on the rows path,
  # so return a value-free error naming the plan surface. Deterministic: the server emits
  # `explainPlan` ONLY for EXPLAIN/PROFILE, and only as an ENVELOPE key (never a row field),
  # so this never false-positives on user data. Covers query/command/query_stream via the one
  # shared `handle_result -> normalize/1` funnel; the plan path uses `normalize_plan/1` and is
  # unaffected. The message names the response shape, never the statement/params (Rule 3).
  def normalize(%{"explainPlan" => _}) do
    {:error,
     %Arcadic.Error{
       reason: :use_explain,
       message:
         "EXPLAIN/PROFILE returns an execution tree, not rows — use Arcadic.explain/4 or Arcadic.profile/4"
     }}
  end

  def normalize(body) when is_map(body) do
    {:ok, extract_rows(body)}
  end

  @doc """
  Extract the EXPLAIN/PROFILE plan envelope: `{:ok, %{plan, plan_tree, rows}}`.

  ## Examples

      iex> Arcadic.Result.normalize_plan(%{"explain" => "plan", "explainPlan" => %{}, "result" => []})
      {:ok, %{rows: [], plan: "plan", plan_tree: %{}}}

  """
  @spec normalize_plan(map()) :: {:ok, %{plan: String.t(), plan_tree: map(), rows: [map()]}}
  def normalize_plan(body) when is_map(body) do
    explain = Map.get(body, "explain")
    explain_plan = Map.get(body, "explainPlan")

    {:ok,
     %{
       plan: if(is_binary(explain), do: explain, else: ""),
       plan_tree: if(is_map(explain_plan), do: explain_plan, else: %{}),
       rows: extract_rows(body)
     }}
  end

  # Shared `result`-list extraction + per-row @props strip (was inline in normalize/1).
  defp extract_rows(body) do
    case Map.get(body, "result", []) do
      list when is_list(list) -> Enum.map(list, &strip_row/1)
      # A missing or non-list `result` (no-result command / DDL / out-of-contract
      # scalar) is an empty row set — never a crash.
      _ -> []
    end
  end

  defp strip_row(row) when is_map(row), do: Map.drop(row, @stripped_keys)
  defp strip_row(row), do: row
end
