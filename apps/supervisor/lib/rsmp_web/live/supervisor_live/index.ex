defmodule RSMP.Supervisor.Web.SupervisorLive.Index do
  use RSMP.Supervisor.Web, :live_view
  use Phoenix.Component

  require Logger

  @impl true
  def mount(params, session, socket) do
    case connected?(socket) do
      true ->
        connected_mount(params, session, socket)

      false ->
        initial_mount(params, session, socket)
    end
  end

  def initial_mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       sites: %{}
     )}
  end

  def connected_mount(_params, _session, socket) do
    Phoenix.PubSub.subscribe(RSMP.PubSub, "rsmp")
    sites = RSMP.Supervisor.sites()

    {:ok,
     assign(socket,
       sites: sort_sites(sites)
     )}
  end

  def sort_sites(sites) do
    sites
    |> Map.to_list()
    |> Enum.sort_by(fn {id, state} -> {state.online == false, id} end, :asc)
  end

  @impl true
  def handle_event(
        "alarm",
        %{"site-id" => site_id, "path" => path, "flag" => flag, "value" => value},
        socket
      ) do
    RSMP.Supervisor.set_alarm_flag(
      site_id,
      path,
      flag,
      value == "true"
    )

    {:noreply, socket}
  end

  @impl true
  def handle_event(name, data, socket) do
    Logger.info("unhandled event: #{inspect([name, data])}")
    {:noreply, socket}
  end

  @impl true
  def handle_info(%{topic: "sites", sites: sites}, socket) do
    {:noreply, assign(socket, sites: sort_sites(sites))}
  end

  @impl true
  def handle_info(%{topic: "status", sites: sites}, socket) do
    {:noreply, assign(socket, sites: sort_sites(sites))}
  end

  @impl true
  def handle_info(%{topic: "alarm", sites: sites}, socket) do
    {:noreply, assign(socket, sites: sort_sites(sites))}
  end

  @impl true
  def handle_info(%{topic: topic} = data, socket) do
    Logger.info("unhandled info: #{inspect([topic, data])}")
    {:noreply, socket}
  end

  @impl true
  def handle_info(%{topic: "alarm", id: _id, path: _path, alarm: _alarm}, socket) do
    sites = RSMP.Supervisor.sites() |> sort_sites()

    {:noreply, assign(socket, sites: sites)}
  end
end
