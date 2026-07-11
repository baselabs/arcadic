defmodule Arcadic.MixProject do
  use Mix.Project

  @version "0.5.0"
  @source_url "https://github.com/baselabs/arcadic"

  def project do
    [
      app: :arcadic,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      consolidate_protocols: Mix.env() != :test,
      deps: deps(),
      package: package(),
      docs: docs(),
      aliases: aliases(),
      name: "Arcadic",
      description:
        "A lean, framework-agnostic Elixir client for ArcadeDB over the HTTP Cypher command API.",
      source_url: @source_url,
      homepage_url: @source_url,
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_core_path: "priv/plts",
        plt_local_path: "priv/plts"
      ]
    ]
  end

  def cli do
    [preferred_envs: [credo: :test, dialyzer: :test]]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Runtime
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"},
      {:boltx, "~> 0.0.6", optional: true},
      {:mint_web_socket, "~> 1.0", optional: true},

      # Dev/Test
      {:plug, "~> 1.0", only: :test},
      {:bandit, "~> 1.0", only: :test},
      {:websock_adapter, "~> 0.5", only: :test},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:benchee, "~> 1.3", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["rjpalermo"],
      files:
        ~w(lib .formatter.exs mix.exs README* LICENSE* CHANGELOG* usage-rules.md CONTRIBUTING.md notebooks),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        "README.md",
        "notebooks/getting_started.livemd",
        "notebooks/graphrag.livemd",
        "usage-rules.md",
        "CHANGELOG.md",
        "CONTRIBUTING.md",
        "LICENSE"
      ],
      groups_for_modules: [
        Core: [
          Arcadic,
          Arcadic.Conn,
          Arcadic.Result,
          Arcadic.Error,
          Arcadic.TransportError,
          Arcadic.Opts,
          Arcadic.Identifier,
          Arcadic.Telemetry,
          Arcadic.Param
        ],
        Transport: [Arcadic.Transport, Arcadic.Transport.HTTP, Arcadic.Transport.Bolt],
        "Schema & data": [
          Arcadic.Schema,
          Arcadic.Import,
          Arcadic.Export,
          Arcadic.Vector,
          Arcadic.FullText,
          Arcadic.Bulk
        ],
        Migrations: [Arcadic.Migration, Arcadic.MigrationRegistry, Arcadic.Migrator],
        "Admin & operations": [Arcadic.Server, Arcadic.Security, Arcadic.Backup],
        "Events & programmability": [
          Arcadic.Changes,
          Arcadic.Function,
          Arcadic.Trigger,
          Arcadic.MaterializedView,
          Arcadic.Geo
        ],
        Transactions: [Arcadic.Transaction]
      ]
    ]
  end

  defp aliases do
    [
      quality: ["format --check-formatted", "credo --strict", "dialyzer"],
      # `mix deps.audit` is MixAudit's own CVE-scan task — do NOT alias it (an alias of
      # the same name shadows it and can't call it without recursion). `mix audit` is the
      # composite: unused-lock check + retired-hex check + MixAudit's CVE scan.
      audit: ["deps.unlock --check-unused", "hex.audit", "deps.audit"]
    ]
  end
end
