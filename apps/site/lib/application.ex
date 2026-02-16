defmodule RSMP.Site.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Generate a persistent site ID at boot
    site_id = RSMP.Node.TLC.make_site_id()
    Application.put_env(:site, :site_id, site_id)

    children = [
      # Start the Telemetry supervisor
      RSMP.Site.Web.Telemetry,
      # Start Finch
      {Finch, name: RSMP.Site.Finch},
      # Start the TLC node (MQTT connection + services)
      {RSMP.Node.TLC, site_id},
      # Start the Endpoint (http/https)
      RSMP.Site.Web.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: RSMP.Site.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    RSMP.Site.Web.Endpoint.config_change(changed, removed)
    :ok
  end
end
