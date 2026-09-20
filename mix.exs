defmodule DebtReliefTracker.MixProject do
  use Mix.Project

  def project do
    [
      app: :debt_relief_tracker,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {DebtReliefTracker.Application, []},
      # :inets/:ssl are Assent's default HTTP adapter (:httpc) for OIDC calls.
      extra_applications: [:logger, :runtime_tools, :inets, :ssl]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.0"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, ">= 0.0.0"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:nimble_csv, "~> 1.0"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 0.26"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      # Application-level field encryption (docs/architecture/0005-field-level-encryption.md).
      {:cloak, "~> 1.1"},
      {:cloak_ecto, "~> 1.3"},
      # Optional OIDC login (docs/architecture/0002-auth-and-sharing-model.md).
      # Uses Erlang's built-in :httpc as its HTTP adapter (Assent's default),
      # so no extra HTTP client dependency is needed.
      {:assent, "~> 0.3"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: [
        "deps.get",
        "ecto.setup",
        "assets.setup",
        "cmd --cd assets npm install",
        "assets.build"
      ],
      # Only the Sqlite repo is targeted here: it's the self-hosted default,
      # and the two-repo setup (docs/architecture/0001-dual-database-adapter.md)
      # means the untargeted ecto.* tasks would otherwise try (and fail) to
      # also set up Repo.Postgres, which has no local config.
      "ecto.setup": [
        "ecto.create -r DebtReliefTracker.Repo.Sqlite",
        "ecto.migrate -r DebtReliefTracker.Repo.Sqlite"
      ],
      "ecto.reset": ["ecto.drop -r DebtReliefTracker.Repo.Sqlite", "ecto.setup"],
      test: [
        "ecto.create --quiet -r DebtReliefTracker.Repo.Sqlite",
        "ecto.migrate --quiet -r DebtReliefTracker.Repo.Sqlite",
        "test"
      ],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind debt_relief_tracker", "esbuild debt_relief_tracker"],
      "assets.deploy": [
        "tailwind debt_relief_tracker --minify",
        "esbuild debt_relief_tracker --minify",
        "phx.digest"
      ],
      precommit: ["compile --warning-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
