defmodule ObanCodex.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/genagent/oban_codex"

  def project do
    [
      app: :oban_codex,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts"
      ],
      description:
        "Run Codex jobs on an Oban queue, with validated args, result helpers, telemetry, and an optional long-lived agent lifecycle.",
      package: package(),
      name: "oban_codex",
      source_url: @source_url,
      docs: [
        main: "readme",
        source_ref: "v#{@version}",
        extras: [
          "README.md",
          "guides/getting_started.md",
          "guides/agent_worker_patterns.md",
          "guides/agent_lifecycle.md",
          "CHANGELOG.md"
        ],
        groups_for_extras: [
          Guides: [
            "guides/getting_started.md",
            "guides/agent_worker_patterns.md",
            "guides/agent_lifecycle.md"
          ]
        ],
        groups_for_modules: [
          "Agent lifecycle": [
            ObanCodex.Agent,
            ObanCodex.Agent.Instance,
            ObanCodex.Agent.Job,
            ObanCodex.Agent.Supervisor,
            ObanCodex.Agent.Tick
          ]
        ]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:oban, "~> 2.23"},
      # The thin seam onto `codex exec`. Keep this on a deliberate 0.x minor:
      # ObanCodex mirrors the Exec and ExecResume option vocabularies.
      {:codex_wrapper, "~> 0.4.0"},
      # Schema for `ObanCodex.Args`: validates the builder's options and
      # generates their documentation from a single source of truth.
      {:nimble_options, "~> 1.1"},
      # Used to verify `:meta` values are JSON-clean at build time (the same
      # encoder Oban serializes args with), so a bad value fails at construction
      # rather than deep inside `Oban.insert`.
      {:jason, "~> 1.4"},
      # Backs the `mix oban_codex` command tree (run/doctor/args): parsing,
      # validation, help, and completion from one declarative command definition.
      # A regular dep (the tasks are user-facing, unlike the dev-only Igniter
      # installer), but zero-runtime-dependencies, so it stays light.
      {:cheer, "~> 0.2"},
      # `~> 1.3`, not `~> 1.2`: oban `~> 2.23` already requires telemetry 1.3+,
      # so a 1.2.x floor is unsatisfiable in any valid resolution.
      {:telemetry, "~> 1.3"},
      # Dev/test only: powers the `mix oban_codex.install` Igniter task. The
      # task module only compiles when Igniter is loaded, so it never ships as a
      # runtime dependency of the library.
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:ex_doc, "~> 0.34", only: [:dev, :test], runtime: false},
      # Dev/test only: backs the SQLite (Lite) Oban engine used by integration
      # tests and examples. Never a runtime dep of the library.
      {:ecto_sqlite3, "~> 0.17", only: [:dev, :test]},
      # Static analysis. Never runtime deps.
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      # Hex's default file set omits guides/ and examples/, but the README (the
      # hexdocs landing page) tells readers to `mix run examples/<name>.exs` --
      # so ship them.
      files:
        ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md SPEC.md guides examples),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "https://hexdocs.pm/oban_codex/changelog.html"
      }
    ]
  end
end
