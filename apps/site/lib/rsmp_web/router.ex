defmodule RSMP.Site.Web.Router do
  use RSMP.Site.Web, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {RSMP.Site.Web.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", RSMP.Site.Web do
    pipe_through :browser

    live "/", SiteLive.Index
  end
end
