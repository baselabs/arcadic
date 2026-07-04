defmodule Arcadic.Telemetry do
  @moduledoc """
  Value-free `:telemetry.span/3` wrapper. Owns the metadata allowlist — the single
  enforcement point for "no statement text, no params, no values, and NO database
  name" (the DB name is the tenant/mode selector upstream; tenant-blind includes
  telemetry). An off-allowlist key raises rather than shipping identity downstream.
  Mirrors `ash_age`'s R7 allowlist pattern.
  """

  @allowed_meta_keys ~w(language mode http_status reason row_count in_transaction? isolation async?)a

  @doc "The permitted span metadata keys."
  @spec allowed_meta_keys() :: [atom()]
  def allowed_meta_keys, do: @allowed_meta_keys

  @doc """
  Runs `fun` inside `:telemetry.span([:arcadic, op], …)`. `fun` returns
  `{result, stop_meta}`; every start/stop metadata key MUST be in the allowlist or
  an `ArgumentError` is raised.
  """
  @spec span(atom(), map(), (-> {term(), map()})) :: term()
  def span(op, start_meta, fun) when is_atom(op) and is_map(start_meta) and is_function(fun, 0) do
    :telemetry.span([:arcadic, op], validate!(start_meta), fn ->
      {result, stop_meta} = fun.()
      {result, validate!(Map.merge(start_meta, stop_meta))}
    end)
  end

  @doc false
  @spec validate!(map()) :: map()
  def validate!(meta) when is_map(meta) do
    case Map.keys(meta) -- @allowed_meta_keys do
      [] ->
        meta

      bad ->
        raise ArgumentError,
              "telemetry metadata keys #{inspect(bad)} are not in the value-free allowlist " <>
                "#{inspect(@allowed_meta_keys)} (no statement/params/values/database name)"
    end
  end
end
