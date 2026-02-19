defmodule RSMP.Site.Web.SitesLive.Index do
  use RSMP.Site.Web, :live_view
  use Phoenix.Component

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(RSMP.PubSub, "sites")
      for id <- RSMP.Sites.list_sites() do
        Phoenix.PubSub.subscribe(RSMP.PubSub, "site:#{id}")
      end
    end

    {:ok, assign(socket, sites: sites_with_status())}
  end

  defp sites_with_status do
    for id <- RSMP.Sites.list_sites() do
      connected = try do
        RSMP.Connection.connected?(id)
      rescue
        _ -> false
      end
      {id, connected}
    end
  end

  @impl true
  def handle_event("add_site", _params, socket) do
    case RSMP.Sites.start_site() do
      {:ok, _id} -> :ok
      {:error, reason} -> Logger.warning("Failed to start site: #{inspect(reason)}")
    end

    {:noreply, assign(socket, sites: sites_with_status())}
  end

  @impl true
  def handle_event("remove_site", %{"id" => id}, socket) do
    RSMP.Sites.stop_site(id)
    {:noreply, assign(socket, sites: sites_with_status())}
  end

  @impl true
  def handle_info(%{topic: "sites_changed"}, socket) do
    for {id, _} <- sites_with_status() do
      Phoenix.PubSub.subscribe(RSMP.PubSub, "site:#{id}")
    end
    {:noreply, assign(socket, sites: sites_with_status())}
  end

  @impl true
  def handle_info(%{topic: "connected"}, socket) do
    {:noreply, assign(socket, sites: sites_with_status())}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end
end
