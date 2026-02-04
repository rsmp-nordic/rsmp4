defmodule RSMP.Supervisor.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Start the Telemetry supervisor
      RSMP.Supervisor.Web.Telemetry,
      # Start Finch
      {Finch, name: RSMP.Supervisor.Finch},
      # Start the Endpoint (http/https)
      RSMP.Supervisor.Web.Endpoint,
      # Start our RSMP supervisor
      RSMP.Supervisor
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: RSMP.Application.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    RSMP.Supervisor.Web.Endpoint.config_change(changed, removed)
    :ok
  end
end
