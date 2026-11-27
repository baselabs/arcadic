defmodule Arcadic.RidFilter do
  @moduledoc false

  @rid_pattern ~r/\A#\d+:\d+\z/

  # Vector options ignore empty filters on the server. Callers that support an empty
  # candidate set handle it before validating or sending a filter.
  @spec validate!(term()) :: [String.t()]
  def validate!([_ | _] = rids) do
    validate_each!(rids)
    rids
  end

  def validate!(_), do: raise(ArgumentError, "filter must be a non-empty list of RIDs")

  defp validate_each!([]), do: :ok

  defp validate_each!([rid | rest]) when is_binary(rid) do
    unless Regex.match?(@rid_pattern, rid), do: invalid_rid!()
    validate_each!(rest)
  end

  defp validate_each!(_), do: invalid_rid!()

  defp invalid_rid!,
    do: raise(ArgumentError, "filter must be a list of #<bucket>:<pos> RID strings")
end
