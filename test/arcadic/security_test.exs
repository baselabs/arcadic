defmodule Arcadic.SecurityTest do
  use ExUnit.Case, async: true
  alias Arcadic.{Conn, Security}

  defp conn,
    do:
      Conn.new("http://a.invalid", "db",
        auth: {"root", "x"},
        transport_options: [plug: {Req.Test, __MODULE__}]
      )

  test "login/1 returns the token; users/1 & sessions/1 return the result list" do
    Req.Test.stub(__MODULE__, fn c ->
      cond do
        c.request_path == "/api/v1/login" ->
          Req.Test.json(c, %{"token" => "AU-t", "user" => "root"})

        c.request_path == "/api/v1/sessions" ->
          Req.Test.json(c, %{"result" => [%{"token" => "AU-t"}], "count" => 1})

        true ->
          Req.Test.json(c, %{"result" => [%{"name" => "root"}]})
      end
    end)

    assert {:ok, "AU-t"} = Security.login(conn())
    assert {:ok, [%{"name" => "root"}]} = Security.users(conn())
    assert {:ok, [%{"token" => "AU-t"}]} = Security.sessions(conn())
  end

  test "create_user/2 Jason-encodes the spec into `create user <json>` and validates the name" do
    Req.Test.stub(__MODULE__, fn c ->
      send(self(), {:cmd, Jason.decode!(Req.Test.raw_body(c))["command"]})
      Req.Test.json(c, %{"result" => "ok"})
    end)

    assert :ok =
             Security.create_user(conn(), %{
               name: "alice",
               password: "hunter2xyz",
               databases: %{"db" => ["admin"]}
             })

    assert_received {:cmd, cmd}

    assert cmd ==
             ~s(create user {"databases":{"db":["admin"]},"name":"alice","password":"hunter2xyz"})

    # invalid name → value-free {:error, :invalid_identifier}, no wire
    assert {:error, :invalid_identifier} =
             Security.create_user(conn(), %{name: "bad name", password: "hunter2xyz"})
  end

  test "create_user/2 NEVER echoes the password in a raised error, even when the server body carries it (Rule 3)" do
    # Red-capable: the fixture body deliberately EMBEDS the attempted password in both `error` and
    # `detail`, simulating a hypothetical leaky server. arcadic's Error must quarantine both from
    # message/1 and inspect/1 — an Error.message/1 that exposed `detail`/`message` would turn this red
    # (the earlier password-FREE fixture could not catch that regression).
    # Produce a REAL 403 (the pipe form — put_status + json compose; a bare `&&` discards the status).
    Req.Test.stub(__MODULE__, fn c ->
      c
      |> Plug.Conn.put_status(403)
      |> Req.Test.json(%{
        "error" => "Security error creating user (password SUPERSECRET_pw)",
        "detail" => "rejected password SUPERSECRET_pw for user 'x'",
        "exception" => "java.lang.SecurityException"
      })
    end)

    e =
      assert_raise Arcadic.Error, fn ->
        Security.create_user!(conn(), %{name: "x", password: "SUPERSECRET_pw"})
      end

    refute Exception.message(e) =~ "SUPERSECRET_pw"
    refute inspect(e) =~ "SUPERSECRET_pw"
  end

  test "create_user/2 with a malformed spec never raises FunctionClauseError (which would echo the password) — value-free {:error, :invalid_user_spec}, no wire (Rule 3)" do
    # The is_binary head guard has a value-free fallback: a non-binary name/password, or a spec
    # missing :name/:password, must NOT reach the head-clause failure (whose FunctionClauseError blame
    # echoes the full spec map — password included). All map to {:error, :invalid_user_spec} value-free.
    Req.Test.stub(__MODULE__, fn c ->
      send(self(), :wire)
      Req.Test.json(c, %{"result" => "ok"})
    end)

    # non-binary name alongside a real password
    r1 = Security.create_user(conn(), %{name: 999, password: "SUPERSECRET_pw"})
    # the classic footgun: `password: 'secret'` is a charlist, is_binary/1 false
    r2 = Security.create_user(conn(), %{name: "alice", password: ~c"SUPERSECRET_pw"})
    # spec missing :password
    r3 = Security.create_user(conn(), %{name: "alice"})

    assert r1 == {:error, :invalid_user_spec}
    assert r2 == {:error, :invalid_user_spec}
    assert r3 == {:error, :invalid_user_spec}
    refute_received :wire
    refute inspect({r1, r2, r3}) =~ "SUPERSECRET_pw"
  end

  test "create_user/2 with a non-UTF8 binary password → value-free {:error, :invalid_user_spec}, no wire, no bytes (Rule 3)" do
    # A non-UTF8 binary PASSES the `is_binary` guard but makes a raising `Jason.encode!` blow up
    # with the raw bytes ("invalid byte 0xFF in <<255, ..., SECRET>>") — a password leak. The
    # non-raising encode must reject value-free and never touch the wire.
    Req.Test.stub(__MODULE__, fn c ->
      send(self(), :wire)
      Req.Test.json(c, %{"result" => "ok"})
    end)

    result = Security.create_user(conn(), %{name: "alice", password: <<0xFF, 0xFE, "SECRET">>})
    assert {:error, :invalid_user_spec} = result
    refute_received :wire
    refute inspect(result) =~ "SECRET"
  end

  test "drop_user/2 validates the name" do
    Req.Test.stub(__MODULE__, fn c ->
      send(self(), :wire)
      Req.Test.json(c, %{"result" => "ok"})
    end)

    assert {:error, :invalid_identifier} = Security.drop_user(conn(), "bad;name")
    refute_received :wire
  end

  test "drop_user/2 valid name → :ok, interpolates `drop user <name>`" do
    Req.Test.stub(__MODULE__, fn c ->
      send(self(), {:cmd, Jason.decode!(Req.Test.raw_body(c))["command"]})
      Req.Test.json(c, %{"result" => "ok"})
    end)

    assert :ok = Security.drop_user(conn(), "alice")
    assert_received {:cmd, "drop user alice"}
  end

  test "logout/1, groups/1 & api_tokens/1 hit their paths and shape their results" do
    # A `case` with no catch-all: a wrong request_path raises CaseClauseError → the test goes red,
    # so a URL-path typo (e.g. `/api/v1/server/api-tokens`) or an Admin.result wiring slip is caught.
    Req.Test.stub(__MODULE__, fn c ->
      case c.request_path do
        "/api/v1/logout" ->
          Plug.Conn.send_resp(c, 204, "")

        "/api/v1/server/groups" ->
          Req.Test.json(c, %{"result" => %{"admin" => %{"types" => %{}}}})

        "/api/v1/server/api-tokens" ->
          Req.Test.json(c, %{"result" => [], "count" => 0})
      end
    end)

    assert :ok = Security.logout(conn())
    # groups returns the map (not a list)
    assert {:ok, %{"admin" => %{"types" => %{}}}} = Security.groups(conn())
    assert {:ok, []} = Security.api_tokens(conn())
  end

  test "login!/1 unwraps {:ok, value} to the bare token (bang value path)" do
    Req.Test.stub(__MODULE__, fn c -> Req.Test.json(c, %{"token" => "AU-t", "user" => "root"}) end)

    assert "AU-t" = Security.login!(conn())
  end
end
