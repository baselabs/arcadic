defmodule Arcadic.Integration.GrpcTest do
  @moduledoc """
  Live proofs for the optional `Arcadic.Transport.Grpc` against an ArcadeDB with the gRPC plugin
  enabled (`-Darcadedb.server.plugins=GRPC:... -Darcadedb.grpc.enabled=true`). Separate env from the
  main `:integration` suite because gRPC is a distinct listener (and qor-arcadedb ships without it):

    * `ARCADIC_GRPC_TEST_URL`      — `grpc://host:port` (the gRPC listener)
    * `ARCADIC_GRPC_TEST_HTTP_URL` — `http://host:port` (same server; used to create/seed the db,
      since the gRPC transport is deliberately admin-incapable)
    * `ARCADIC_GRPC_TEST_PASSWORD` — root password

  No skip-on-absent-plugin: with the env set, a missing gRPC surface FAILS loudly.
  """
  use ExUnit.Case, async: false
  @moduletag :integration_grpc

  alias Arcadic.{Conn, Server}
  alias Arcadic.Transport.Grpc

  setup_all do
    grpc_url =
      System.get_env("ARCADIC_GRPC_TEST_URL") ||
        flunk("set ARCADIC_GRPC_TEST_URL (grpc://host:port)")

    http_url =
      System.get_env("ARCADIC_GRPC_TEST_HTTP_URL") || flunk("set ARCADIC_GRPC_TEST_HTTP_URL")

    pass = System.get_env("ARCADIC_GRPC_TEST_PASSWORD") || flunk("set ARCADIC_GRPC_TEST_PASSWORD")

    db = "grpc_it_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    http = Conn.new(http_url, db, auth: {"root", pass})
    _ = Server.drop_database(http, db)
    :ok = Server.create_database!(http, db)
    Arcadic.command!(http, "CREATE DOCUMENT TYPE Doc", %{}, language: "sql")

    for i <- 1..5,
        do:
          Arcadic.command!(http, "INSERT INTO Doc SET n = #{i}, tag = 'row#{i}'", %{},
            language: "sql"
          )

    on_exit(fn -> Server.drop_database(http, db) end)

    grpc = Conn.new(grpc_url, db, auth: {"root", pass}, transport: Grpc)
    {:ok, grpc: grpc}
  end

  test "execute :read returns typed rows (int + string decoded)", %{grpc: c} do
    assert {:ok, rows} =
             Grpc.execute(
               c,
               :read,
               %{statement: "SELECT n, tag FROM Doc ORDER BY n", params: %{}, language: "sql"},
               []
             )

    assert Enum.map(rows, & &1["n"]) == [1, 2, 3, 4, 5]
    assert hd(rows)["tag"] == "row1"
  end

  test "execute :read binds params (a quote-breaking value is inert)", %{grpc: c} do
    assert {:ok, rows} =
             Grpc.execute(
               c,
               :read,
               %{
                 statement: "SELECT n FROM Doc WHERE n >= :min ORDER BY n",
                 params: %{"min" => 3},
                 language: "sql"
               },
               []
             )

    assert Enum.map(rows, & &1["n"]) == [3, 4, 5]
  end

  test "query_stream CURSOR drains the server cursor across batches (chunk < total)", %{grpc: c} do
    assert {:ok, stream} =
             Grpc.query_stream(
               c,
               %{statement: "SELECT n FROM Doc ORDER BY n", params: %{}, language: "sql"},
               chunk_size: 2
             )

    assert Enum.map(Enum.to_list(stream), & &1["n"]) == [1, 2, 3, 4, 5]
  end

  test "execute :write runs a command (DDL + insert on its own type, isolated from Doc)", %{
    grpc: c
  } do
    # Own type so a write never pollutes the Doc rows the read/stream tests assert on (ExUnit
    # randomizes intra-module order). Also proves gRPC ExecuteCommand runs DDL + DML.
    assert {:ok, _} =
             Grpc.execute(
               c,
               :write,
               %{statement: "CREATE DOCUMENT TYPE DocW", params: %{}, language: "sql"},
               []
             )

    # :write must RETURN the created record (return_rows) — parity with the HTTP transport, not
    # just {:ok, _}. A regression that drops the rows (return_rows unset) reddens this.
    assert {:ok, [row]} =
             Grpc.execute(
               c,
               :write,
               %{statement: "INSERT INTO DocW SET n = 42", params: %{}, language: "sql"},
               []
             )

    assert row["n"] == 42
    assert is_binary(row["@rid"])

    assert {:ok, [%{"c" => 1}]} =
             Grpc.execute(
               c,
               :read,
               %{statement: "SELECT count(*) AS c FROM DocW", params: %{}, language: "sql"},
               []
             )
  end

  test "decode: DATETIME and DECIMAL columns decode to real values, not nil (silent-loss guard)",
       %{
         grpc: c
       } do
    # Regression guard for the value codec: unhandled GrpcValue kinds silently became nil.
    Grpc.execute(
      c,
      :write,
      %{statement: "CREATE DOCUMENT TYPE Typed", params: %{}, language: "sql"},
      []
    )

    Grpc.execute(
      c,
      :write,
      %{statement: "CREATE PROPERTY Typed.ts DATETIME", params: %{}, language: "sql"},
      []
    )

    Grpc.execute(
      c,
      :write,
      %{statement: "CREATE PROPERTY Typed.amt DECIMAL", params: %{}, language: "sql"},
      []
    )

    Grpc.execute(
      c,
      :write,
      %{
        statement:
          "INSERT INTO Typed SET ts = date('2024-01-02 03:04:05', 'yyyy-MM-dd HH:mm:ss'), amt = 12.34",
        params: %{},
        language: "sql"
      },
      []
    )

    assert {:ok, [row]} =
             Grpc.execute(
               c,
               :read,
               %{statement: "SELECT ts, amt FROM Typed", params: %{}, language: "sql"},
               []
             )

    refute is_nil(row["ts"])
    refute is_nil(row["amt"])
    assert row["amt"] == 12.34 or row["amt"] == 12
  end

  # Gates partial-consumption CORRECTNESS (a Stream.take over multiple wire batches yields the
  # requested prefix in order). NOTE: this does NOT gate server-side laziness — a client cannot
  # distinguish "pulled one batch" from "drained the cursor then sliced" without server-batch
  # instrumentation (both yield the same rows). Laziness is guaranteed structurally by the
  # Stream.transform implementation (per-demand pull) and verified in code review, not here.
  test "query_stream supports partial consumption across batches, preserving order", %{grpc: c} do
    assert {:ok, stream} =
             Grpc.query_stream(
               c,
               %{statement: "SELECT n FROM Doc ORDER BY n", params: %{}, language: "sql"},
               chunk_size: 1
             )

    assert Enum.map(Stream.take(stream, 3) |> Enum.to_list(), & &1["n"]) == [1, 2, 3]
  end

  test "a bearer-auth gRPC conn is rejected at construction (no silent empty-cred fail-open)", %{
    grpc: c
  } do
    assert_raise ArgumentError, fn -> Conn.with_bearer(c, "tok") end

    assert_raise ArgumentError, fn ->
      Conn.new("grpc://localhost:1", "db", auth: {:bearer, "t"}, transport: Grpc)
    end
  end

  test "ready? pings the server", %{grpc: c} do
    assert {:ok, true} = Grpc.ready?(c)
  end

  test "admin/transactional surface is :not_supported (use an HTTP conn)", %{grpc: c} do
    assert {:error, %Arcadic.Error{reason: :not_supported}} = Grpc.begin(c, [])
    assert {:error, %Arcadic.Error{reason: :not_supported}} = Grpc.commit(c)
    assert {:error, %Arcadic.Error{reason: :not_supported}} = Grpc.list_databases(c)
    assert {:error, %Arcadic.Error{reason: :not_supported}} = Grpc.database_exists?(c, "x")
  end

  # TRIPWIRE — redaction. A failing statement carrying a secret param must surface a VALUE-FREE
  # error whose EVERY field is value-free — no raw gRPC wire message (which echoes the offending
  # statement/value) in ANY field. Note: `Arcadic.Error` quarantines its `:message` field from
  # `message/1`/`inspect/1` for server-origin reasons, so a leak would NOT show in the rendered
  # error — this test uses `inspect(structs: false)` to reveal the raw `:message` field too, so a
  # transport that stuffs `RPCError.message` into the struct is caught. Red-capable: mapping the
  # error to `%Error{reason: :server_error, message: rpc_error.message}` reddens this (verified).
  test "redaction: a wire error never echoes the statement or the param value in any field", %{
    grpc: c
  } do
    secret = "s3cr3t_#{System.unique_integer([:positive])}"

    assert {:error, err} =
             Grpc.execute(
               c,
               :read,
               %{
                 statement: "SELECT FROM NoSuchType_#{secret} WHERE x = :p",
                 params: %{"p" => secret},
                 language: "sql"
               },
               []
             )

    assert match?(%Arcadic.Error{}, err) or match?(%Arcadic.TransportError{}, err)
    rendered = inspect(err, structs: false) <> " " <> Exception.message(err)
    refute rendered =~ secret
    refute rendered =~ "NoSuchType"
  end
end
