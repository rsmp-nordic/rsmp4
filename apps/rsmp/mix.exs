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
      elixir: "~> 1.16",
      deps: deps()
    ]
  end

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.7.7"},
      {:phoenix_html, "~> 3.3"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 0.19.0"},
      {:secure_random, "~> 0.5"},
      {:emqtt, github: "emqx/emqtt", system_env: [{"BUILD_WITHOUT_QUIC", "1"}]},
      {:poison, "~> 5.0"},
      {:cbor, "~> 1.0.1"}
    ]
  end
end
