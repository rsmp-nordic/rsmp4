defmodule RSMP.Site.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Start the Telemetry supervisor
      RSMP.Site.Web.Telemetry,
      # Start Finch
      {Finch, name: RSMP.Site.Finch},
      # Start the Endpoint (http/https)
      RSMP.Site.Web.Endpoint
    ]

    opts = [strategy: :one_for_one, name: RSMP.Site.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    RSMP.Site.Web.Endpoint.config_change(changed, removed)
    :ok
  end
end
