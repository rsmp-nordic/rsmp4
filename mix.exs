defmodule RSMP4.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      consolidate_protocols: false,
      listeners: [Phoenix.CodeReloader],
      start_permanent: Mix.env() == :prod
    ]
  end
end
