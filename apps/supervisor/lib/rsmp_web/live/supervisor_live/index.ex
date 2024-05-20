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
    {:ok, sort_sites(socket)}
  end

  def sort_sites(socket) do
    assign(socket,
      sites:
        RSMP.Supervisor.sites()
        |> Map.to_list()
        |> Enum.sort_by(fn {id, state} -> {state.online == false, id} end, :asc)
    )
  end

  @impl true
  def handle_event(
        "alarm",
        %{"site-id" => site_id, "path" => path, "flag" => flag, "value" => value},
        socket
      ) do
    RSMP.Supervisor.set_alarm_flag(
      site_id,
      RSMP.Path.from_string(path),
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
  def handle_info(%{topic: "state"}, socket) do
    {:noreply, sort_sites(socket)}
  end

  @impl true
  def handle_info(%{topic: "status"}, socket) do
    {:noreply, sort_sites(socket)}
  end

  @impl true
  def handle_info(%{topic: "alarm"}, socket) do
    {:noreply, sort_sites(socket)}
  end

  @impl true
  def handle_info(%{topic: topic} = data, socket) do
    Logger.info("unhandled info x: #{inspect([topic, data])}")
    {:noreply, socket}
  end
end
