defmodule RSMP.Supervisor.MixProject do
  use Mix.Project

  def project do
    [
      app: :supervisor,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {RSMP.Supervisor.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:rsmp, in_umbrella: true},
      {:phoenix, "~> 1.8.3"},
      {:phoenix_html, "~> 4.3.0"},
      {:phoenix_live_reload, "~> 1.6.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.22"},
      {:floki, ">= 0.38.0", only: :test},
      {:esbuild, "~> 0.10.0", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.4.1", runtime: Mix.env() == :dev},
      {:swoosh, "~> 1.21.0"},
      {:finch, "~> 0.21.0"},
      {:telemetry_metrics, "~> 1.1.0"},
      {:telemetry_poller, "~> 1.3.0"},
      {:jason, "~> 1.4.4"},
      {:plug_cowboy, "~> 2.7.5"},
      {:cowlib, "~> 2.12.1", override: true},
      {:secure_random, "~> 0.5"},
      {:emqtt, github: "emqx/emqtt", system_env: [{"BUILD_WITHOUT_QUIC", "1"}]},
      {:poison, "~> 6.0"}
    ]
  end
end
