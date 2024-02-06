defmodule RSMPWeb.Router do
  use RSMPWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {RSMPWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", RSMPWeb do
    pipe_through :browser

    live "/", SupervisorLive.Index, :list
    live "/client/:client_id", SupervisorLive.Client, :client
  end
end
