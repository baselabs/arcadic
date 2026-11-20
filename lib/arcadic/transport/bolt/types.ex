defmodule Arcadic.Transport.Bolt.Types do
  @moduledoc """
  Bolt values owned by arcadic. `Bytes` distinguishes binary data from UTF-8 strings.
  `Structure` preserves a PackStream signature and its fields, including unknown
  extensions. `Temporal` preserves nanoseconds and the wire epoch/zone without
  depending on a time zone database. Legacy datetime signatures use local seconds;
  UTC datetime signatures use UTC seconds, as defined by Bolt.
  """

  defmodule Bytes do
    @moduledoc "A Bolt byte array, distinct from a UTF-8 string."
    @derive {Inspect, only: []}
    defstruct [:data]
    @type t :: %__MODULE__{data: binary()}
  end

  defmodule Structure do
    @moduledoc "A PackStream structure with a byte signature and ordered fields."
    @derive {Inspect, only: [:signature]}
    defstruct [:signature, fields: []]
    @type t :: %__MODULE__{signature: byte(), fields: list()}
  end

  defmodule Float do
    @moduledoc "An IEEE 754 non-finite value, preserved as 64 raw bits."
    @derive {Inspect, only: []}
    defstruct [:bits]
    @type t :: %__MODULE__{bits: non_neg_integer()}
  end

  defmodule Node do
    @moduledoc "A Bolt node."
    @derive {Inspect, only: []}
    defstruct [:id, :labels, :properties]
    @type t :: %__MODULE__{id: integer(), labels: list(), properties: map()}
  end

  defmodule Relationship do
    @moduledoc "A Bolt relationship."
    @derive {Inspect, only: []}
    defstruct [:id, :start, :end, :type, :properties]

    @type t :: %__MODULE__{
            id: integer(),
            start: integer(),
            end: integer(),
            type: String.t(),
            properties: map()
          }
  end

  defmodule UnboundRelationship do
    @moduledoc "A relationship in a Bolt path."
    @derive {Inspect, only: []}
    defstruct [:id, :type, :properties]
    @type t :: %__MODULE__{id: integer(), type: String.t(), properties: map()}
  end

  defmodule Path do
    @moduledoc "A Bolt path with unique nodes/relationships and signed traversal indices."
    @derive {Inspect, only: []}
    defstruct [:nodes, :relationships, :indices]
    @type t :: %__MODULE__{nodes: list(), relationships: list(), indices: [integer()]}
  end

  defmodule Temporal do
    @moduledoc "A lossless Bolt date/time structure; see the Bolt structure semantics."
    @derive {Inspect, only: [:signature]}
    defstruct [:signature, :fields]
    @type t :: %__MODULE__{signature: byte(), fields: list()}
  end

  defmodule Duration do
    @moduledoc "A Bolt duration with calendar months/days and elapsed seconds/nanoseconds."
    @derive {Inspect, only: []}
    defstruct months: 0, days: 0, seconds: 0, nanoseconds: 0

    @type t :: %__MODULE__{
            months: integer(),
            days: integer(),
            seconds: integer(),
            nanoseconds: integer()
          }
  end

  defmodule Point do
    @moduledoc "A Bolt point. SRIDs: 7203/9157 (Cartesian), 4326/4979 (WGS-84)."
    @derive {Inspect, only: []}
    defstruct [:srid, :x, :y, :z]
    @type t :: %__MODULE__{srid: integer(), x: float(), y: float(), z: float() | nil}
  end

  @doc false
  def dump(%Node{id: id, labels: labels, properties: props}), do: {0x4E, [id, labels, props]}

  def dump(%Relationship{id: id, start: s, end: e, type: t, properties: p}),
    do: {0x52, [id, s, e, t, p]}

  def dump(%UnboundRelationship{id: id, type: t, properties: p}), do: {0x72, [id, t, p]}
  def dump(%Path{nodes: n, relationships: r, indices: i}), do: {0x50, [n, r, i]}
  def dump(%Duration{months: m, days: d, seconds: s, nanoseconds: n}), do: {0x45, [m, d, s, n]}
  def dump(%Point{srid: s, x: x, y: y, z: nil}), do: {0x58, [s, x, y]}
  def dump(%Point{srid: s, x: x, y: y, z: z}), do: {0x59, [s, x, y, z]}
  def dump(%Temporal{signature: s, fields: f}), do: {s, f}
  def dump(%Date{} = d), do: {0x44, [Date.diff(d, ~D[1970-01-01])]}
  def dump(%Time{} = t), do: {0x74, [Time.diff(t, ~T[00:00:00], :nanosecond)]}

  def dump(%NaiveDateTime{} = d),
    do: {0x64, [NaiveDateTime.diff(d, ~N[1970-01-01 00:00:00]), elem(d.microsecond, 0) * 1000]}

  def dump(%DateTime{} = d),
    do:
      {0x46,
       [
         DateTime.to_unix(d) + d.utc_offset + d.std_offset,
         elem(d.microsecond, 0) * 1000,
         d.utc_offset + d.std_offset
       ]}

  def dump(_), do: :error

  @doc false
  def hydrate(%Structure{signature: 0x4E, fields: [id, l, p]}),
    do: %Node{id: id, labels: l, properties: hydrate(p)}

  def hydrate(%Structure{signature: 0x52, fields: [id, s, e, t, p]}),
    do: %Relationship{id: id, start: s, end: e, type: t, properties: hydrate(p)}

  def hydrate(%Structure{signature: 0x72, fields: [id, t, p]}),
    do: %UnboundRelationship{id: id, type: t, properties: hydrate(p)}

  def hydrate(%Structure{signature: 0x50, fields: [n, r, i]}),
    do: %Path{nodes: hydrate(n), relationships: hydrate(r), indices: i}

  def hydrate(%Structure{signature: 0x45, fields: [m, d, s, n]}),
    do: %Duration{months: m, days: d, seconds: s, nanoseconds: n}

  def hydrate(%Structure{signature: 0x58, fields: [s, x, y]}), do: %Point{srid: s, x: x, y: y}

  def hydrate(%Structure{signature: 0x59, fields: [s, x, y, z]}),
    do: %Point{srid: s, x: x, y: y, z: z}

  def hydrate(%Structure{signature: s, fields: f})
      when s in [0x44, 0x54, 0x74, 0x64, 0x46, 0x66, 0x49, 0x69],
      do: %Temporal{signature: s, fields: f}

  def hydrate(%Structure{} = s), do: %{s | fields: hydrate(s.fields)}
  def hydrate(l) when is_list(l), do: Enum.map(l, &hydrate/1)
  def hydrate(%{__struct__: _} = v), do: v
  def hydrate(m) when is_map(m), do: Map.new(m, fn {k, v} -> {k, hydrate(v)} end)
  def hydrate(v), do: v
end
