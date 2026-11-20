defmodule Arcadic.Transport.Bolt.PackStream do
  @moduledoc false
  alias Arcadic.{Error, TransportError}
  alias Arcadic.Transport.Bolt.Types
  alias Arcadic.Transport.Bolt.Types.{Bytes, Structure}

  # Bound recursive work on untrusted input. Container lengths are checked against
  # remaining bytes before traversal, so a hostile count never allocates a list.
  @max_depth 128

  @spec encode(term()) :: {:ok, binary()} | {:error, Error.t()}
  def encode(value) do
    {:ok, value |> pack(0) |> IO.iodata_to_binary()}
  rescue
    _ -> {:error, %Error{reason: :invalid_params}}
  catch
    :invalid -> {:error, %Error{reason: :invalid_params}}
  end

  @spec decode(binary()) :: {:ok, term(), binary()} | {:error, TransportError.t()}
  def decode(data) when is_binary(data) do
    case unpack(data, 0) do
      {:ok, _, _} = ok -> ok
      :error -> {:error, %TransportError{reason: :bolt_protocol_error}}
    end
  end

  def decode(_), do: {:error, %TransportError{reason: :bolt_protocol_error}}

  defp pack(_, d) when d > @max_depth, do: throw(:invalid)
  defp pack(nil, _), do: <<0xC0>>
  defp pack(false, _), do: <<0xC2>>
  defp pack(true, _), do: <<0xC3>>
  defp pack(n, _) when is_integer(n) and n >= -16 and n < 128, do: <<n::signed-8>>
  defp pack(n, _) when is_integer(n) and n >= -128 and n < 128, do: <<0xC8, n::signed-8>>
  defp pack(n, _) when is_integer(n) and n >= -32768 and n < 32768, do: <<0xC9, n::signed-16>>

  defp pack(n, _) when is_integer(n) and n >= -2_147_483_648 and n < 2_147_483_648,
    do: <<0xCA, n::signed-32>>

  defp pack(n, _)
       when is_integer(n) and n >= -9_223_372_036_854_775_808 and n <= 9_223_372_036_854_775_807,
       do: <<0xCB, n::signed-64>>

  defp pack(n, _) when is_float(n), do: <<0xC1, n::float-64>>

  defp pack(%Types.Float{bits: b}, _) when is_integer(b) and b >= 0 and b <= 0xFFFFFFFFFFFFFFFF,
    do: <<0xC1, b::64>>

  defp pack(s, _) when is_binary(s) do
    if String.valid?(s), do: [header(byte_size(s), 0x80, 0xD0), s], else: throw(:invalid)
  end

  defp pack(%Bytes{data: b}, _) when is_binary(b), do: [header(byte_size(b), nil, 0xCC), b]

  defp pack(%Structure{signature: s, fields: f}, d)
       when is_integer(s) and s in 0..255 and is_list(f) and length(f) < 16 do
    [<<0xB0 + length(f), s>> | Enum.map(f, &pack(&1, d + 1))]
  end

  defp pack(%{__struct__: _} = s, d) do
    case Types.dump(s) do
      {signature, fields} -> pack(%Structure{signature: signature, fields: fields}, d)
      :error -> throw(:invalid)
    end
  end

  defp pack(l, d) when is_list(l),
    do: [header(length(l), 0x90, 0xD4) | Enum.map(l, &pack(&1, d + 1))]

  defp pack(m, d) when is_map(m) do
    pairs = Enum.map(m, fn {k, v} -> [pack(key(k), d + 1), pack(v, d + 1)] end)
    [header(map_size(m), 0xA0, 0xD8) | pairs]
  end

  defp pack(_, _), do: throw(:invalid)

  defp key(k) when is_binary(k), do: k
  defp key(k) when is_atom(k), do: Atom.to_string(k)
  defp key(_), do: throw(:invalid)
  defp header(n, tiny, _) when is_integer(tiny) and n < 16, do: <<tiny + n>>
  defp header(n, _, base) when n < 256, do: <<base, n>>
  defp header(n, _, base) when n < 65536, do: <<base + 1, n::16>>
  defp header(n, _, base) when n < 4_294_967_296, do: <<base + 2, n::32>>

  defp unpack(_, d) when d > @max_depth, do: :error
  defp unpack(<<n, rest::binary>>, _) when n < 128, do: {:ok, n, rest}
  defp unpack(<<n::signed-8, rest::binary>>, _) when n >= -16 and n < 0, do: {:ok, n, rest}
  defp unpack(<<0xC0, rest::binary>>, _), do: {:ok, nil, rest}
  defp unpack(<<0xC2, rest::binary>>, _), do: {:ok, false, rest}
  defp unpack(<<0xC3, rest::binary>>, _), do: {:ok, true, rest}
  defp unpack(<<0xC8, n::signed-8, rest::binary>>, _), do: {:ok, n, rest}
  defp unpack(<<0xC9, n::signed-16, rest::binary>>, _), do: {:ok, n, rest}
  defp unpack(<<0xCA, n::signed-32, rest::binary>>, _), do: {:ok, n, rest}
  defp unpack(<<0xCB, n::signed-64, rest::binary>>, _), do: {:ok, n, rest}
  defp unpack(<<0xC1, n::float-64, rest::binary>>, _), do: {:ok, n, rest}
  defp unpack(<<0xC1, b::64, rest::binary>>, _), do: {:ok, %Types.Float{bits: b}, rest}

  defp unpack(<<marker, rest::binary>>, d) when marker in 0x80..0x8F,
    do: sized(:string, marker - 0x80, rest, d)

  defp unpack(<<marker, rest::binary>>, d) when marker in 0x90..0x9F,
    do: sized(:list, marker - 0x90, rest, d)

  defp unpack(<<marker, rest::binary>>, d) when marker in 0xA0..0xAF,
    do: sized(:map, marker - 0xA0, rest, d)

  defp unpack(<<marker, signature, rest::binary>>, d) when marker in 0xB0..0xBF do
    with {:ok, fields, rest} <- items(marker - 0xB0, rest, d + 1, []),
         do: {:ok, %Structure{signature: signature, fields: fields}, rest}
  end

  for {kind, base} <- [bytes: 0xCC, string: 0xD0, list: 0xD4, map: 0xD8],
      {offset, bits} <- [{0, 8}, {1, 16}, {2, 32}] do
    defp unpack(<<unquote(base + offset), n::unsigned-size(unquote(bits)), rest::binary>>, d),
      do: sized(unquote(kind), n, rest, d)
  end

  defp unpack(_, _), do: :error

  defp sized(:string, n, data, _) when byte_size(data) >= n do
    <<s::binary-size(n), rest::binary>> = data
    if String.valid?(s), do: {:ok, s, rest}, else: :error
  end

  defp sized(:bytes, n, data, _) when byte_size(data) >= n do
    <<b::binary-size(n), rest::binary>> = data
    {:ok, %Bytes{data: b}, rest}
  end

  defp sized(:list, n, data, d), do: items(n, data, d + 1, [])
  defp sized(:map, n, data, d) when n * 2 <= byte_size(data), do: pairs(n, data, d + 1, %{})
  defp sized(_, _, _, _), do: :error

  defp items(0, data, _, acc), do: {:ok, Enum.reverse(acc), data}

  defp items(n, data, d, acc) when n > 0 and n <= byte_size(data) do
    with {:ok, v, rest} <- unpack(data, d), do: items(n - 1, rest, d, [v | acc])
  end

  defp items(_, _, _, _), do: :error

  defp pairs(0, data, _, acc), do: {:ok, acc, data}

  defp pairs(n, data, d, acc) do
    with {:ok, k, rest} when is_binary(k) <- unpack(data, d),
         false <- Map.has_key?(acc, k),
         {:ok, v, rest} <- unpack(rest, d) do
      pairs(n - 1, rest, d, Map.put(acc, k, v))
    else
      _ -> :error
    end
  end
end
