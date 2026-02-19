defmodule RSMP.Supervisor.Web.Router do
  use RSMP.Supervisor.Web, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {RSMP.Supervisor.Web.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", RSMP.Supervisor.Web do
    pipe_through :browser

    live "/", SupervisorsLive.Index, :list
    live "/supervisor/:supervisor_id", SupervisorLive.Index, :list
    live "/supervisor/:supervisor_id/site/:site_id", SupervisorLive.Site, :site
  end
end
