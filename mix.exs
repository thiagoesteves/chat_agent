defmodule ChatAgent.MixProject do
  use Mix.Project

  def project do
    [
      app: :chat_agent,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      dialyzer: dialyzer(),
      docs: docs(),
      test_coverage: test_coverage(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {ChatAgent.Application, []},
      extra_applications: [:logger, :runtime_tools]
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
      {:phoenix, "~> 1.8.9"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:mox, "~> 1.2", only: :test},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:req, "~> 0.6.1"},

      # Static analysis, security, and documentation. None of these ship in the
      # release: they are build-time only, hence `runtime: false`.
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false}
    ]
  end

  # Dialyzer needs a PLT built from the app's dependencies. Caching it under
  # priv/plts keeps CI from rebuilding it on every run.
  defp dialyzer do
    [
      plt_add_apps: [:mix, :ex_unit],
      plt_file: {:no_warn, "priv/plts/project.plt"},
      plt_core_path: "priv/plts",
      flags: [:error_handling, :underspecs, :unknown]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      groups_for_modules: [
        Domain: [~r/^ChatAgent\.(?!Application)/],
        Web: [~r/^ChatAgentWeb\./]
      ]
    ]
  end

  # `mix test --cover` fails below the threshold, so coverage is a gate rather
  # than a number nobody reads.
  defp test_coverage do
    [
      summary: [threshold: 90],
      ignore_modules: [
        # OTP and test scaffolding. Counting these as covered product code
        # flatters the number for no reason.
        ChatAgent.Application,
        ChatAgentWeb.ConnCase,
        # `embed_templates` generates layout and error page functions, and cover
        # does not attribute execution back to them.
        ChatAgentWeb.CoreComponents,
        ChatAgentWeb.ErrorHTML,
        ChatAgentWeb.Layouts,
        ChatAgentWeb.PageHTML,
        # Metrics are defined at startup and not exercised by unit tests.
        ChatAgentWeb.Telemetry
      ]
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get"],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "test --cover",
        "credo --strict"
      ]
    ]
  end
end
