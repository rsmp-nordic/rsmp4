defmodule RSMP.MixProject do
  use Mix.Project

  def project do
    [
      app: :rsmp,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20.0-rc.1",
      deps: deps(),
      consolidate_protocols: false
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {RSMP.Application, []},
      extra_applications: [:logger]
    ]
  end

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.3"},
      {:phoenix_html, "~> 4.3.0"},
      {:phoenix_live_reload, "~> 1.6.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.22"},
      {:secure_random, "~> 0.5"},
      {:emqtt, github: "emqx/emqtt", system_env: [{"BUILD_WITHOUT_QUIC", "1"}]},
      {:poison, "~> 6.0"},
      {:jason, "~> 1.4.4"},
      {:cbor, "~> 1.0.1"}
    ]
  end
end
