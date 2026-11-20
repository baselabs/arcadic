# The Bolt transport exists only where DBConnection is present;
# the condition is the one lib/arcadic/transport/bolt.ex compiles under.
if Code.ensure_loaded?(DBConnection) do
  defmodule Arcadic.Transport.Bolt.WireTest do
    use ExUnit.Case, async: true
    alias Arcadic.Test.BoltFakeServer
    alias Arcadic.Transport.Bolt.{Client, Connection, Framing, PackStream, Query, Response}
    alias Arcadic.Transport.Bolt.Types.Structure

    # Independently written Bolt v4 fixtures. A SUCCESS map and RECORD [1].
    @success <<0, 3, 0xB1, 0x70, 0xA0, 0, 0>>
    @record <<0, 4, 0xB1, 0x71, 0x91, 1, 0, 0>>

    defp client(fun) do
      {:ok, port} = BoltFakeServer.start_script(fun)
      {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
      on_exit(fn -> :gen_tcp.close(sock) end)
      %Client{sock: {:gen_tcp, sock}, bolt_version: {4, 4}}
    end

    defp recv_frame(sock, acc \\ []) do
      {:ok, <<n::16>>} = :gen_tcp.recv(sock, 2, 1000)

      if n == 0 do
        acc |> Enum.reverse() |> IO.iodata_to_binary()
      else
        {:ok, chunk} = :gen_tcp.recv(sock, n, 1000)
        recv_frame(sock, [chunk | acc])
      end
    end

    test "every control message has its specified signature, fields and chunk terminator" do
      parent = self()

      requests = [
        {:reset, [], <<0xB0, 0x0F>>},
        {:begin, [%{db: "d"}], <<0xB1, 0x11, 0xA1, 0x82, "db", 0x81, ?d>>},
        {:commit, [], <<0xB0, 0x12>>},
        {:rollback, [], <<0xB0, 0x13>>},
        {:discard, [%{n: -1}], <<0xB1, 0x2F, 0xA1, 0x81, ?n, 0xFF>>}
      ]

      c =
        client(fn sock ->
          for {name, _, _} <- requests do
            send(parent, {name, recv_frame(sock)})
            :gen_tcp.send(sock, @success)
          end

          send(parent, {:goodbye, recv_frame(sock)})
        end)

      for {name, fields, bytes} <- requests do
        assert {:ok, %{}} = Client.request(c, name, fields, 1000)
        assert_receive {^name, ^bytes}
      end

      assert :ok = Client.goodbye(c)
      assert_receive {:goodbye, <<0xB0, 0x02>>}
    end

    test "RUN, RECORD and PULL use real byte fixtures across fragmented chunks and NOOPs" do
      parent = self()

      c =
        client(fn sock ->
          send(parent, {:run, recv_frame(sock)})
          # SUCCESS {fields: [n]}, deliberately fragmented into two Bolt chunks.
          :gen_tcp.send(
            sock,
            <<0, 0, 0, 2, 0xB1, 0x70, 0, 11, 0xA1, 0x86, "fields", 0x91, 0x81, ?n, 0, 0>>
          )

          send(parent, {:pull, recv_frame(sock)})
          # Send each byte individually, independent of TCP packet boundaries.
          for <<byte <- @record <> @success>>, do: :gen_tcp.send(sock, <<byte>>)
        end)

      assert {:ok, run} = Client.request(c, :run, ["RETURN 1", %{}, %{db: "d"}], 1000)
      assert_receive {:run, <<0xB3, 0x10, 0x88, "RETURN 1", 0xA0, 0xA1, 0x82, "db", 0x81, ?d>>}
      assert {:ok, pull} = Client.request(c, :pull, [%{n: 1}], 1000)
      assert_receive {:pull, <<0xB1, 0x3F, 0xA1, 0x81, ?n, 1>>}
      assert {:ok, %Response{results: [%{"n" => 1}]}} = Response.new(run, pull)
    end

    test "framing splits at 65_535 bytes and reassembles multi-chunk messages" do
      value = :binary.copy(<<42>>, 65_536)
      bytes = value |> Framing.encode() |> IO.iodata_to_binary()
      assert <<65_535::16, _::binary-size(65_535), 1::16, 42, 0::16>> = bytes

      c =
        client(fn sock ->
          :gen_tcp.send(sock, bytes)
          _ = :gen_tcp.recv(sock, 1, 1000)
        end)

      assert {:ok, ^value} = Framing.recv(c.sock, Framing.deadline(1000))
    end

    test "FAILURE drops free text and arbitrary status strings, including nested data" do
      for code <- ["Neo.ClientError.Security.Unauthorized", "SECRET_UNKNOWN_STATUS"] do
        c =
          client(fn sock ->
            _ = recv_frame(sock)

            {:ok, p} =
              PackStream.encode(%Structure{
                signature: 0x7F,
                fields: [
                  %{
                    "code" => code,
                    "message" => "SERVER_SECRET",
                    "extra" => [%{"password" => "SERVER_SECRET"}]
                  }
                ]
              })

            :gen_tcp.send(sock, Framing.encode(p))
          end)

        assert {:error, %Arcadic.Error{} = e} = Client.request(c, :reset, [], 1000)
        refute inspect(e) =~ "SECRET"
        refute Exception.message(e) =~ "SECRET"
        assert e.message == nil
        assert e.detail == nil

        assert e.reason ==
                 if(code == "Neo.ClientError.Security.Unauthorized",
                   do: :unauthorized,
                   else: :server_error
                 )
      end
    end

    test "IGNORED, invalid signatures, trailing bytes and malformed records fail typed" do
      for payload <- [
            <<0xB0, 0x7E>>,
            <<0xB0, 0x33>>,
            <<0xB1, 0x70, 0xA0, 42>>,
            <<0xB1, 0x71, 1>>,
            <<0xB1, 0x70, 0x81, ?x>>
          ] do
        c =
          client(fn sock ->
            _ = recv_frame(sock)
            :gen_tcp.send(sock, [<<byte_size(payload)::16>>, payload, <<0, 0>>])
          end)

        assert {:error, :bolt_protocol_error} = Client.request(c, :reset, [], 1000)
      end
    end

    test "truncated header, chunk and PackStream payload never raise or retain bytes" do
      for bytes <- [<<0>>, <<0, 8, "SECRET">>, <<0, 2, 0xB1, 0x70, 0, 0>>] do
        c =
          client(fn sock ->
            _ = recv_frame(sock)
            :gen_tcp.send(sock, bytes)
          end)

        assert {:error, e} = Client.request(c, :reset, [], 1000)

        assert e in [
                 :closed,
                 :bolt_protocol_error,
                 %Arcadic.TransportError{reason: :bolt_protocol_error}
               ]

        refute inspect(e) =~ "SECRET"
      end
    end

    test "one deadline bounds an entire fragmented reply and pending data is disconnected" do
      c =
        client(fn sock ->
          _ = recv_frame(sock)
          :gen_tcp.send(sock, <<0, 1, 0xB1>>)
          Process.sleep(:infinity)
        end)

      state = %{client: c, status: :idle, cursor_open?: false}
      query = %Query{statement: "RETURN $secret", extra: %{db: "d"}}

      assert {:disconnect, %Arcadic.TransportError{reason: :timeout}, _} =
               Connection.handle_execute(query, %{"secret" => "SENSITIVE"}, [timeout: 20], state)

      refute inspect(query) =~ "secret"
      assert to_string(query) == "[BOLT]"
    end

    test "an expired deadline rejects even buffered data and NOOP floods" do
      parent = self()

      c =
        client(fn sock ->
          :gen_tcp.send(sock, :binary.copy(<<0, 0>>, 1000) <> @success)
          send(parent, :buffered)
          _ = :gen_tcp.recv(sock, 1, 1000)
        end)

      assert_receive :buffered
      assert {:error, :timeout} = Framing.recv(c.sock, Framing.deadline(0))
    end

    test "handshake advertises four versions and authenticates with HELLO on the bounded socket" do
      parent = self()

      {:ok, port} =
        BoltFakeServer.start_script(fn sock ->
          {:ok, handshake} = :gen_tcp.recv(sock, 20, 1000)
          send(parent, {:handshake, handshake})
          :gen_tcp.send(sock, <<0, 0, 4, 4>>)
          send(parent, {:hello, recv_frame(sock)})
          :gen_tcp.send(sock, @success)
          _ = recv_frame(sock)
        end)

      assert {:ok, state} =
               Client.connect(
                 hostname: "127.0.0.1",
                 port: port,
                 auth: [username: "u", password: "p"],
                 connect_timeout: 1000
               )

      assert_receive {:handshake,
                      <<0x60, 0x60, 0xB0, 0x17, 0, 0, 4, 4, 0, 0, 3, 4, 0, 0, 2, 4, 0, 0, 1, 4>>}

      assert_receive {:hello, bytes}
      assert {:ok, %Structure{signature: 1, fields: [hello]}, ""} = PackStream.decode(bytes)

      assert hello == %{
               "user_agent" => "arcadic",
               "scheme" => "basic",
               "principal" => "u",
               "credentials" => "p"
             }

      assert state.client.bolt_version == {4, 4}
      Connection.disconnect(:normal, state)
    end

    test "an unoffered version is rejected before HELLO" do
      {:ok, port} =
        BoltFakeServer.start_script(fn sock ->
          {:ok, _} = :gen_tcp.recv(sock, 20, 1000)
          :gen_tcp.send(sock, <<0, 0, 3, 4>>)
        end)

      assert {:error, :version_negotiation_error} =
               Client.connect(hostname: "127.0.0.1", port: port, versions: [4.4])
    end
  end
end
