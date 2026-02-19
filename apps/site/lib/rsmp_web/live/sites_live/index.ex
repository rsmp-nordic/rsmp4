defmodule RSMP.Site.Web.SitesLive.Index do
  use RSMP.Site.Web, :live_view
  use Phoenix.Component

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(RSMP.PubSub, "sites")
    end

    {:ok, assign(socket, sites: RSMP.Sites.list_sites())}
  end

  @impl true
  def handle_event("add_site", _params, socket) do
    case RSMP.Sites.start_site() do
      {:ok, _id} -> :ok
      {:error, reason} -> Logger.warning("Failed to start site: #{inspect(reason)}")
    end

    {:noreply, assign(socket, sites: RSMP.Sites.list_sites())}
  end

  @impl true
  def handle_event("remove_site", %{"id" => id}, socket) do
    RSMP.Sites.stop_site(id)
    {:noreply, assign(socket, sites: RSMP.Sites.list_sites())}
  end

  @impl true
  def handle_info(%{topic: "sites_changed"}, socket) do
    {:noreply, assign(socket, sites: RSMP.Sites.list_sites())}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end
end
