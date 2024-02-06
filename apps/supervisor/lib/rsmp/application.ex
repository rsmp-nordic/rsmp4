defmodule RSMP.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Start the Telemetry supervisor
      RSMPWeb.Telemetry,
      # Start the PubSub system
      {Phoenix.PubSub, name: RSMP.PubSub},
      # Start Finch
      {Finch, name: RSMP.Finch},
      # Start the Endpoint (http/https)
      RSMPWeb.Endpoint,
      # Start or registry
      {Registry, keys: :unique, name: RSMP.Registry},
      # Start our RSMP supervisor
      RSMP.Supervisor
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: RSMP.AppSupervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    RSMPWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
