defmodule Arcadic.Transport.Bolt.PackStreamTest do
  use ExUnit.Case, async: true
  alias Arcadic.Transport.Bolt.{PackStream, Types}
  alias Arcadic.Transport.Bolt.Types.{Bytes, Structure}

  test "scalar wire fixtures, every integer width and boundary, and signed zero" do
    fixtures = [
      {nil, <<0xC0>>},
      {false, <<0xC2>>},
      {true, <<0xC3>>},
      {-16, <<0xF0>>},
      {-17, <<0xC8, 0xEF>>},
      {-128, <<0xC8, 0x80>>},
      {-129, <<0xC9, 0xFF, 0x7F>>},
      {-32_768, <<0xC9, 0x80, 0>>},
      {-32_769, <<0xCA, 0xFF, 0xFF, 0x7F, 0xFF>>},
      {-2_147_483_648, <<0xCA, 0x80, 0, 0, 0>>},
      {-2_147_483_649, <<0xCB, -2_147_483_649::signed-64>>},
      {-9_223_372_036_854_775_808, <<0xCB, 0x80, 0, 0, 0, 0, 0, 0, 0>>},
      {0, <<0>>},
      {127, <<127>>},
      {128, <<0xC9, 0, 128>>},
      {32_767, <<0xC9, 0x7F, 0xFF>>},
      {32_768, <<0xCA, 0, 0, 128, 0>>},
      {2_147_483_647, <<0xCA, 0x7F, 0xFF, 0xFF, 0xFF>>},
      {2_147_483_648, <<0xCB, 2_147_483_648::64>>},
      {9_223_372_036_854_775_807, <<0xCB, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>},
      {0.0, <<0xC1, 0::64>>},
      {-0.0, <<0xC1, 0x8000000000000000::64>>},
      {1.5, <<0xC1, 0x3FF8000000000000::64>>},
      {"", <<0x80>>},
      {"é", <<0x82, 0xC3, 0xA9>>},
      {[], <<0x90>>},
      {%{}, <<0xA0>>},
      {%{"a" => [1, nil]}, <<0xA1, 0x81, ?a, 0x92, 1, 0xC0>>},
      {%Bytes{data: <<0, 255>>}, <<0xCC, 2, 0, 255>>},
      {%Structure{signature: 0x70, fields: [%{}]}, <<0xB1, 0x70, 0xA0>>}
    ]

    for {value, bytes} <- fixtures do
      assert {:ok, ^bytes} = PackStream.encode(value)
      assert {:ok, decoded, <<42>>} = PackStream.decode(bytes <> <<42>>)
      assert {:ok, ^bytes} = PackStream.encode(decoded)
    end

    # Non-canonical but valid integer encodings decode too.
    assert {:ok, 127, ""} = PackStream.decode(<<0xC8, 127>>)
  end

  test "all container length encodings and nested values round trip" do
    for n <- [0, 15, 16, 255, 256, 65_535, 65_536] do
      for value <- [
            String.duplicate("x", n),
            %Bytes{data: :binary.copy(<<255>>, n)},
            List.duplicate(nil, n)
          ] do
        assert {:ok, bytes} = PackStream.encode(value)
        assert {:ok, ^value, ""} = PackStream.decode(bytes)
      end
    end

    for n <- [0, 15, 16, 255, 256, 65_536] do
      value =
        Map.new(List.duplicate(nil, n) |> Enum.with_index(), fn {_, i} ->
          {Integer.to_string(i), i}
        end)

      assert {:ok, bytes} = PackStream.encode(value)
      assert {:ok, ^value, ""} = PackStream.decode(bytes)
    end

    assert {:ok, <<0xD0, 16, _::binary>>} = PackStream.encode(String.duplicate("x", 16))
    assert {:ok, <<0xD1, 256::16, _::binary>>} = PackStream.encode(String.duplicate("x", 256))

    assert {:ok, <<0xD2, 65_536::32, _::binary>>} =
             PackStream.encode(String.duplicate("x", 65_536))
  end

  test "non-finite IEEE values retain their bits without a BEAM float exception" do
    for bits <- [0x7FF0000000000000, 0xFFF0000000000000, 0x7FF8000000000001] do
      assert {:ok, %Types.Float{bits: ^bits} = v, ""} = PackStream.decode(<<0xC1, bits::64>>)
      assert {:ok, <<0xC1, ^bits::64>>} = PackStream.encode(v)
    end
  end

  test "every prefix of a compound value and every reserved marker fails value-free" do
    values = [
      "secret@example.com",
      %Bytes{data: <<255, 0, 1>>},
      [1, %{"x" => [nil, -129, 1.5]}],
      %Structure{signature: 0x52, fields: [1, 2, 3, "E", %{"v" => "secret"}]}
    ]

    for value <- values do
      {:ok, bytes} = PackStream.encode(value)

      for n <- 0..(byte_size(bytes) - 1) do
        assert {:error, %Arcadic.TransportError{reason: :bolt_protocol_error}} =
                 PackStream.decode(binary_part(bytes, 0, n))
      end
    end

    for bytes <- [
          <<0xC4>>,
          <<0xC5>>,
          <<0xC6>>,
          <<0xC7>>,
          <<0xCF>>,
          <<0xD3>>,
          <<0xD7>>,
          <<0xDB>>,
          <<0xDC>>,
          <<0xDD>>,
          <<0xDE>>,
          <<0xDF>>,
          <<0xE0>>,
          <<0xD2, 0xFFFFFFFF::32>>,
          <<0xD6, 0xFFFFFFFF::32>>,
          <<0xDA, 0xFFFFFFFF::32>>,
          <<0xA1, 1, 2>>,
          <<0xA2, 0x81, ?x, 1, 0x81, ?x, 2>>,
          <<0x81, 255>>,
          :binary.copy(<<0x91>>, 130) <> <<0xC0>>
        ] do
      assert {:error, %Arcadic.TransportError{reason: :bolt_protocol_error}} =
               PackStream.decode(bytes)
    end
  end

  test "all one-byte and two-byte inputs decode or return a typed value-free error" do
    for a <- 0..255, b <- 0..255 do
      case PackStream.decode(<<a, b>>) do
        {:ok, _, rest} -> assert is_binary(rest)
        {:error, e} -> assert e == %Arcadic.TransportError{reason: :bolt_protocol_error}
      end
    end
  end

  test "invalid parameters fail without embedding their value in an error" do
    for value <- [
          self(),
          make_ref(),
          {:secret, "secret@example.com"},
          <<255>>,
          9_223_372_036_854_775_808,
          -9_223_372_036_854_775_809,
          %{1 => "secret"}
        ] do
      assert {:error, %Arcadic.Error{reason: :invalid_params} = e} = PackStream.encode(value)
      refute inspect(e) =~ "secret"
    end
  end

  test "graph and temporal signatures match independent byte fixtures" do
    fixtures = [
      {<<0xB3, 0x4E, 1, 0x91, 0x81, ?V, 0xA0>>,
       %Types.Node{id: 1, labels: ["V"], properties: %{}}},
      {<<0xB5, 0x52, 1, 2, 3, 0x81, ?E, 0xA0>>,
       %Types.Relationship{id: 1, start: 2, end: 3, type: "E", properties: %{}}},
      {<<0xB3, 0x72, 1, 0x81, ?E, 0xA0>>,
       %Types.UnboundRelationship{id: 1, type: "E", properties: %{}}},
      {<<0xB3, 0x50, 0x90, 0x90, 0x90>>, %Types.Path{nodes: [], relationships: [], indices: []}},
      {<<0xB4, 0x45, 1, 2, 3, 4>>,
       %Types.Duration{months: 1, days: 2, seconds: 3, nanoseconds: 4}},
      {<<0xB1, 0x44, 1>>, %Types.Temporal{signature: 0x44, fields: [1]}},
      {<<0xB1, 0x74, 1>>, %Types.Temporal{signature: 0x74, fields: [1]}},
      {<<0xB2, 0x54, 1, 2>>, %Types.Temporal{signature: 0x54, fields: [1, 2]}},
      {<<0xB2, 0x64, 1, 2>>, %Types.Temporal{signature: 0x64, fields: [1, 2]}},
      {<<0xB3, 0x46, 1, 2, 3>>, %Types.Temporal{signature: 0x46, fields: [1, 2, 3]}},
      {<<0xB3, 0x66, 1, 2, 0x83, "UTC">>,
       %Types.Temporal{signature: 0x66, fields: [1, 2, "UTC"]}},
      {<<0xB3, 0x49, 1, 2, 3>>, %Types.Temporal{signature: 0x49, fields: [1, 2, 3]}},
      {<<0xB3, 0x69, 1, 2, 0x83, "UTC">>,
       %Types.Temporal{signature: 0x69, fields: [1, 2, "UTC"]}},
      {<<0xB3, 0x58, 0xC9, 7203::16, 0xC1, 1.0::float-64, 0xC1, 2.0::float-64>>,
       %Types.Point{srid: 7203, x: 1.0, y: 2.0}},
      {<<0xB4, 0x59, 0xC9, 4979::16, 0xC1, 1.0::float-64, 0xC1, 2.0::float-64, 0xC1,
         3.0::float-64>>, %Types.Point{srid: 4979, x: 1.0, y: 2.0, z: 3.0}}
    ]

    for {bytes, value} <- fixtures do
      assert {:ok, ^bytes} = PackStream.encode(value)
      assert {:ok, structure, ""} = PackStream.decode(bytes)
      assert Types.hydrate(structure) == value
    end
  end

  test "graph, temporal, and spatial structures retain every field and hydrate recursively" do
    node = %Types.Node{id: 1, labels: ["V"], properties: %{"v" => 3}}
    rel = %Types.UnboundRelationship{id: 2, type: "E", properties: %{}}

    values = [
      node,
      rel,
      %Types.Relationship{id: 2, start: 1, end: 3, type: "E", properties: %{}},
      %Types.Path{nodes: [node], relationships: [rel], indices: [-1, 0]},
      %Types.Duration{months: 1, days: 2, seconds: 3, nanoseconds: 4},
      %Types.Point{srid: 7203, x: 1.0, y: 2.0},
      %Types.Point{srid: 4979, x: 1.0, y: 2.0, z: 3.0}
    ]

    temporal = [
      {0x44, [1]},
      {0x74, [123_456_789]},
      {0x54, [123_456_789, -14_400]},
      {0x64, [123, 987_654_321]},
      {0x46, [123, 987_654_321, -14_400]},
      {0x66, [123, 987_654_321, "America/New_York"]},
      {0x49, [123, 987_654_321, 3600]},
      {0x69, [123, 987_654_321, "UTC"]}
    ]

    values =
      values ++ Enum.map(temporal, fn {s, f} -> %Types.Temporal{signature: s, fields: f} end)

    for value <- values do
      assert {:ok, bytes} = PackStream.encode(value)
      assert {:ok, structure, ""} = PackStream.decode(bytes)
      assert Types.hydrate(structure) == value
    end

    for {v, s, f} <- [
          {~D[1970-01-02], 0x44, [1]},
          {~T[00:00:01.123456], 0x74, [1_123_456_000]},
          {~N[1970-01-01 00:00:01.123456], 0x64, [1, 123_456_000]},
          {~U[1970-01-01 00:00:01.123456Z], 0x46, [1, 123_456_000, 0]}
        ] do
      assert {:ok, bytes} = PackStream.encode(v)
      assert {:ok, %Structure{signature: ^s, fields: ^f}, ""} = PackStream.decode(bytes)
    end
  end
end
