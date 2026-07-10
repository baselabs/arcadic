defmodule Arcadic.Backup do
  @moduledoc """
  Backup and restore over ArcadeDB. `backup/2` runs `BACKUP DATABASE` on `conn.database` (optional
  `:to '<url>'` single-quoted target); `list/1` runs `list backups <db>`; `restore/3` runs
  `restore database <name> <url>`. Tenant-blind.

  URLs are interpolated (server commands / the `BACKUP` SQL literal cannot bind params), so a target
  URL and the restore `<name>`/`<url>` are allowlist-validated value-free BEFORE any wire call:
  `name` via `Arcadic.Identifier`, `url` via `Arcadic.Identifier.validate_url/1` (RFC-3986 positive
  allowlist + `http`/`https`/`file` scheme). The allowlist excludes the single quote `'` (so a `:to`
  URL cannot break out of `BACKUP DATABASE '<url>'`) and newline/space/control (so a restore `<url>`,
  a rest-of-line literal server-side, cannot start a second statement) — that is the only injection
  vector. **SSRF note:** whether the server blocks private/loopback restore sources is
  server-config-dependent — treat the URL as trusted operator input.
  """
  alias Arcadic.{Admin, Conn, Identifier, Opts}

  @doc "Back up `conn.database`. `:to '<url>'` overrides the server's default backup directory."
  @spec backup(Conn.t(), keyword()) :: {:ok, map()} | {:error, atom() | Exception.t()}
  def backup(%Conn{} = conn, opts \\ []) do
    Opts.validate_keys!(opts, [:to])

    with :ok <- valid_target(opts[:to]) do
      Admin.span(:backup, fn -> run_backup(conn, opts[:to]) end)
    end
  end

  defp run_backup(conn, to) do
    statement = if to, do: "BACKUP DATABASE '#{to}'", else: "BACKUP DATABASE"

    with {:ok, rows} <- Admin.sql(conn, statement), do: {:ok, List.first(rows, %{})}
  end

  @doc "List backups for `conn.database` (`list backups <db>`)."
  @spec list(Conn.t()) :: {:ok, map()} | {:error, Exception.t()}
  def list(%Conn{} = conn),
    do: Admin.span(:list_backups, fn -> Admin.command(conn, "list backups #{conn.database}") end)

  @doc "Restore a database `name` from a backup `url` (`restore database <name> <url>`). Validates both."
  @spec restore(Conn.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, atom() | Exception.t()}
  def restore(%Conn{} = conn, name, url) do
    with :ok <- Identifier.validate(name), :ok <- valid_url(url) do
      Admin.span(:restore, fn -> Admin.command(conn, "restore database #{name} #{url}") end)
    end
  end

  @spec backup!(Conn.t(), keyword()) :: map()
  def backup!(%Conn{} = conn, opts \\ []), do: bang(backup(conn, opts))
  @spec list!(Conn.t()) :: map()
  def list!(%Conn{} = conn), do: bang(list(conn))
  @spec restore!(Conn.t(), String.t(), String.t()) :: map()
  def restore!(%Conn{} = conn, name, url), do: bang(restore(conn, name, url))

  defp valid_target(nil), do: :ok
  defp valid_target(url), do: valid_url(url)

  defp valid_url(url) do
    case Identifier.validate_url(url) do
      :ok -> :ok
      {:error, _} -> {:error, :invalid_url}
    end
  end

  defp bang({:ok, value}), do: value
  defp bang({:error, %{__exception__: true} = e}), do: raise(e)

  defp bang({:error, reason}),
    do: raise(ArgumentError, "backup operation failed: #{inspect(reason)}")
end
