defmodule Arcadic.Transport.Bolt.Response do
  @moduledoc false
  alias Arcadic.Transport.Bolt.Types
  alias Arcadic.TransportError

  @derive {Inspect, only: []}
  defstruct results: [],
            fields: [],
            records: [],
            plan: nil,
            profile: nil,
            notifications: [],
            stats: [],
            type: nil,
            bookmark: nil

  @type t :: %__MODULE__{
          results: [map()],
          fields: list(),
          records: list(),
          plan: term(),
          profile: term(),
          notifications: list(),
          stats: term(),
          type: term(),
          bookmark: term()
        }

  def new(run, %{records: records, success: meta}) do
    fields = Map.get(run, "fields", [])

    if is_list(fields) and Enum.all?(fields, &is_binary/1) and
         Enum.all?(records, &(length(&1) == length(fields))) do
      results = Enum.map(records, fn row -> Map.new(Enum.zip(fields, Types.hydrate(row))) end)

      {:ok,
       %__MODULE__{
         results: results,
         fields: fields,
         records: records,
         plan: meta["plan"],
         profile: meta["profile"],
         stats: meta["stats"] || [],
         notifications: meta["notifications"] || [],
         type: meta["type"],
         bookmark: meta["bookmark"]
       }}
    else
      {:error, %TransportError{reason: :bolt_protocol_error}}
    end
  end
end
