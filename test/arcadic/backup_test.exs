defmodule Arcadic.BackupTest do
  use ExUnit.Case, async: true
  alias Arcadic.{Backup, Conn}

  defp conn,
    do:
      Conn.new("http://a.invalid", "db",
        auth: {"root", "x"},
        transport_options: [plug: {Req.Test, __MODULE__}]
      )

  test "backup/2 runs BACKUP DATABASE and (with :to) a single-quoted target" do
    Req.Test.stub(__MODULE__, fn c ->
      send(self(), {:cmd, Jason.decode!(Req.Test.raw_body(c))["command"]})

      Req.Test.json(c, %{
        "result" => [
          %{"operation" => "backup database", "result" => "OK", "backupFile" => "db-backup.zip"}
        ]
      })
    end)

    assert {:ok, %{"backupFile" => "db-backup.zip"}} = Backup.backup(conn())
    assert_received {:cmd, "BACKUP DATABASE"}
    assert {:ok, _} = Backup.backup(conn(), to: "file:///b/db.zip")
    assert_received {:cmd, "BACKUP DATABASE 'file:///b/db.zip'"}
  end

  test "backup/2 rejects an unknown opt key (value-free) before any wire" do
    Req.Test.stub(__MODULE__, fn c ->
      send(self(), :wire)
      Req.Test.json(c, %{"result" => []})
    end)

    assert_raise ArgumentError, fn -> Backup.backup(conn(), bogus: 1) end
    refute_received :wire
  end

  test "backup/2 rejects a bad :to target URL value-free (no wire — same injection surface as restore)" do
    Req.Test.stub(__MODULE__, fn c ->
      send(self(), :wire)
      Req.Test.json(c, %{"result" => []})
    end)

    # newline: the second-statement vector for the single-quoted BACKUP literal
    assert {:error, :invalid_url} = Backup.backup(conn(), to: "file:///a\nDROP")
    # scheme not in the http/https/file allowlist
    assert {:error, :invalid_url} = Backup.backup(conn(), to: "ftp://h/x.zip")
    refute_received :wire
  end

  test "list/1 lists backups for conn.database" do
    Req.Test.stub(__MODULE__, fn c ->
      send(self(), {:cmd, Jason.decode!(Req.Test.raw_body(c))["command"]})
      Req.Test.json(c, %{"database" => "db", "backups" => []})
    end)

    assert {:ok, %{"backups" => []}} = Backup.list(conn())
    assert_received {:cmd, "list backups db"}
  end

  test "restore/3 validates the name AND url value-free (no wire on a bad url — the injection surface)" do
    Req.Test.stub(__MODULE__, fn c ->
      send(self(), :wire)
      Req.Test.json(c, %{"result" => "ok"})
    end)

    assert {:error, :invalid_identifier} = Backup.restore(conn(), "bad name", "file:///b.zip")
    # newline: the rest-of-line vector
    assert {:error, :invalid_url} = Backup.restore(conn(), "db2", "file:///a\nDROP")
    # space
    assert {:error, :invalid_url} = Backup.restore(conn(), "db2", "file:///a b.zip")
    # scheme
    assert {:error, :invalid_url} = Backup.restore(conn(), "db2", "ftp://h/x.zip")
    refute_received :wire
  end

  test "restore/3 sends the command for valid inputs" do
    Req.Test.stub(__MODULE__, fn c ->
      send(self(), {:cmd, Jason.decode!(Req.Test.raw_body(c))["command"]})
      Req.Test.json(c, %{"result" => "ok"})
    end)

    assert {:ok, %{"result" => "ok"}} = Backup.restore(conn(), "db2", "file:///b/db.zip")
    assert_received {:cmd, "restore database db2 file:///b/db.zip"}
  end

  test "backup!/2 & list!/1 unwrap {:ok, value} to the bare map (bang value path)" do
    Req.Test.stub(__MODULE__, fn c ->
      if String.ends_with?(c.request_path, "/server"),
        do: Req.Test.json(c, %{"database" => "db", "backups" => []}),
        else: Req.Test.json(c, %{"result" => [%{"backupFile" => "db-backup.zip"}]})
    end)

    assert %{"backupFile" => "db-backup.zip"} = Backup.backup!(conn())
    assert %{"backups" => []} = Backup.list!(conn())
  end

  test "restore!/3 raises ArgumentError on a bare-atom error (bang atom path)" do
    Req.Test.stub(__MODULE__, fn c ->
      send(self(), :wire)
      Req.Test.json(c, %{"result" => "ok"})
    end)

    assert_raise ArgumentError, ~r/backup operation failed/, fn ->
      Backup.restore!(conn(), "bad name", "file:///x.zip")
    end

    # the bare-atom reject is value-free and pre-wire, so the bang never hits the transport
    refute_received :wire
  end

  test "restore!/3 re-raises a server Arcadic.Error (bang exception path)" do
    Req.Test.stub(__MODULE__, fn c ->
      c
      |> Plug.Conn.put_status(500)
      |> Req.Test.json(%{
        "error" => "Internal error",
        "exception" => "java.lang.RuntimeException"
      })
    end)

    assert_raise Arcadic.Error, fn ->
      Backup.restore!(conn(), "db2", "file:///x.zip")
    end
  end
end
