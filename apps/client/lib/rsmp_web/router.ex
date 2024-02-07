defmodule RSMP.Client.Web.Router do
  use RSMP.Client.Web, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {RSMP.Client.Web.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", RSMP.Client.Web do
    pipe_through :browser

    live "/", ClientLive.Index
  end
end
