defmodule Arcadic.Transport.Bolt.Client do
  @moduledoc false
  alias Arcadic.{Error, TransportError}
  alias Arcadic.Transport.Bolt.{Framing, PackStream}
  alias Arcadic.Transport.Bolt.Types.Structure

  @derive {Inspect, only: [:bolt_version]}
  defstruct [:sock, :bolt_version]
  @type t :: %__MODULE__{sock: {module(), term()}, bolt_version: {4, non_neg_integer()} | nil}

  @messages %{
    hello: 0x01,
    goodbye: 0x02,
    reset: 0x0F,
    run: 0x10,
    begin: 0x11,
    commit: 0x12,
    rollback: 0x13,
    discard: 0x2F,
    pull: 0x3F
  }
  @versions [4.4, 4.3, 4.2, 4.1]

  def connect(opts) do
    deadline = Framing.deadline(Keyword.get(opts, :connect_timeout, 15_000))

    with {:ok, socket} <- open(opts, deadline) do
      client = %__MODULE__{sock: socket}
      establish(client, opts, deadline)
    end
  end

  defp establish(client, opts, deadline) do
    result =
      with {:ok, version} <- handshake(client, opts, deadline),
           client = %{client | bolt_version: version},
           {:ok, meta} <- exchange(client, :hello, [hello(opts)], deadline) do
        {:ok,
         %{
           client: client,
           server_version: meta["server"],
           connection_id: meta["connection_id"],
           hints: meta["hints"],
           patch_bolt: meta["patch_bolt"],
           status: :idle,
           cursor_open?: false,
           first_chunk?: true
         }}
      end

    case result do
      {:ok, _} ->
        result

      {:error, _} ->
        close(client)
        result
    end
  rescue
    _ ->
      close(client)
      {:error, :bolt_protocol_error}
  end

  defp open(opts, deadline) do
    host = Keyword.get(opts, :hostname, "localhost")
    host = if is_binary(host), do: String.to_charlist(host), else: host
    port = Keyword.get(opts, :port, 7687)
    tcp_opts = [:binary, active: false, packet: :raw, nodelay: true]

    open_socket(Keyword.get(opts, :scheme, "bolt"), host, port, tcp_opts, opts, deadline)
  rescue
    _ -> {:error, :invalid_transport_options}
  end

  defp open_socket("bolt", host, port, tcp_opts, _, deadline) do
    socket_result(:gen_tcp.connect(host, port, tcp_opts, Framing.remaining(deadline)), :gen_tcp)
  end

  defp open_socket("bolt+s", host, port, _, opts, deadline) do
    with {:ok, _} <- Application.ensure_all_started(:ssl) do
      ssl_opts =
        opts
        |> Keyword.get(:ssl_opts, [])
        |> tls_options()
        |> Keyword.merge(active: false, mode: :binary, packet: :raw)

      socket_result(:ssl.connect(host, port, ssl_opts, Framing.remaining(deadline)), :ssl)
    end
  end

  defp socket_result({:ok, socket}, mod), do: {:ok, {mod, socket}}
  defp socket_result({:error, error}, _), do: {:error, reason(error)}

  def tls_options(opts) do
    if Keyword.get(opts, :verify) == :verify_none do
      opts
    else
      opts = Keyword.put(opts, :verify, :verify_peer)

      if Keyword.has_key?(opts, :cacerts) or Keyword.has_key?(opts, :cacertfile),
        do: opts,
        else: Keyword.put(opts, :cacerts, :public_key.cacerts_get())
    end
  end

  defp hello(opts) do
    auth = Keyword.get(opts, :auth, [])

    %{
      "user_agent" => "arcadic",
      "scheme" => "basic",
      "principal" => Keyword.get(auth, :username, "root"),
      "credentials" => Keyword.get(auth, :password, "")
    }
  end

  defp handshake(client, opts, deadline) do
    versions = Keyword.get(opts, :versions, @versions)

    if versions == [] or length(versions) > 4 or Enum.any?(versions, &(&1 not in @versions)) do
      {:error, :version_negotiation_error}
    else
      proposals = Enum.map(versions, fn v -> <<0, 0, round((v - 4) * 10), 4>> end)
      padding = :binary.copy(<<0, 0, 0, 0>>, 4 - length(versions))

      with :ok <- send_data(client, [<<0x60, 0x60, 0xB0, 0x17>>, proposals, padding], deadline),
           {:ok, reply} <- recv_version(client, deadline) do
        negotiated(reply, versions)
      end
    end
  end

  defp negotiated(<<0, 0, minor, 4>>, versions) when minor in 1..4 do
    if (4 + minor / 10) in versions,
      do: {:ok, {4, minor}},
      else: {:error, :version_negotiation_error}
  end

  defp negotiated(_, _), do: {:error, :version_negotiation_error}

  defp recv_version(%{sock: socket}, deadline) do
    case Framing.read(socket, 4, deadline) do
      {:ok, _} = ok -> ok
      {:error, e} -> {:error, reason(e)}
    end
  end

  def request(client, name, fields, timeout),
    do: exchange(client, name, fields, Framing.deadline(timeout))

  defp exchange(client, name, fields, deadline) do
    with {:ok, payload} <-
           PackStream.encode(%Structure{signature: Map.fetch!(@messages, name), fields: fields}),
         :ok <- send_data(client, Framing.encode(payload), deadline) do
      receive_response(client, deadline, name, [])
    end
  end

  defp receive_response(client, deadline, name, records) do
    with {:ok, payload} <- Framing.recv(client.sock, deadline),
         {:ok, message, <<>>} <- PackStream.decode(payload) do
      response(message, client, deadline, name, records)
    else
      {:error, %TransportError{} = e} -> {:error, e}
      {:error, e} -> {:error, reason(e)}
      _ -> {:error, :bolt_protocol_error}
    end
  end

  defp response(%Structure{signature: 0x70, fields: [meta]}, _, _, :pull, records)
       when is_map(meta),
       do: {:ok, %{records: Enum.reverse(records), success: meta}}

  defp response(%Structure{signature: 0x70, fields: [meta]}, _, _, _, []) when is_map(meta),
    do: {:ok, meta}

  defp response(%Structure{signature: 0x71, fields: [row]}, client, deadline, :pull, records)
       when is_list(row),
       do: receive_response(client, deadline, :pull, [row | records])

  defp response(%Structure{signature: 0x7F, fields: [meta]}, _, _, _, _) when is_map(meta),
    do: {:error, failure(meta)}

  defp response(%Structure{signature: 0x7E, fields: []}, _, _, _, _),
    do: {:error, :bolt_protocol_error}

  defp response(_, _, _, _, _), do: {:error, :bolt_protocol_error}

  # Retain only known status classes. Neither free text nor an arbitrary string
  # in the code field may escape into Exception.message, inspect, or a crash log.
  @codes %{
    "Neo.ClientError.Security.Unauthorized" => :unauthorized,
    "Neo.ClientError.Security.Forbidden" => :unauthorized,
    "Neo.ClientError.Statement.SyntaxError" => :parse_error,
    "Neo.ClientError.Statement.ParameterMissing" => :server_error,
    "Neo.ClientError.Database.DatabaseNotFound" => :database_not_found,
    "Neo.TransientError.Transaction.DeadlockDetected" => :transaction_error
  }
  def failure(meta) do
    case Map.fetch(@codes, meta["code"]) do
      {:ok, reason} -> %Error{reason: reason, exception: meta["code"]}
      :error -> %Error{reason: :server_error}
    end
  end

  defp send_data(%{sock: {mod, sock}}, data, deadline) do
    setter = if mod == :gen_tcp, do: :inet, else: mod

    with :ok <-
           setter.setopts(sock,
             send_timeout: Framing.remaining(deadline),
             send_timeout_close: true
           ),
         :ok <- mod.send(sock, data) do
      :ok
    else
      {:error, e} -> {:error, reason(e)}
    end
  end

  def goodbye(client) do
    {:ok, payload} = PackStream.encode(%Structure{signature: 0x02})
    send_data(client, Framing.encode(payload), Framing.deadline(1000))
  end

  def close(%{sock: {mod, sock}}) do
    mod.close(sock)
    :ok
  end

  defp reason(e)
       when e in [
              :timeout,
              :closed,
              :econnrefused,
              :ehostunreach,
              :enetunreach,
              :nxdomain,
              :enetdown,
              :econnreset
            ],
       do: e

  defp reason(_), do: :bolt_protocol_error
end
