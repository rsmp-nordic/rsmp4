defmodule RSMP.Supervisor.Web.SupervisorLive.Index do
  use RSMP.Supervisor.Web, :live_view
  use Phoenix.Component

  require Logger

  @impl true
  def mount(params, session, socket) do
    supervisor_id = params["supervisor_id"]
    socket = assign(socket, supervisor_id: supervisor_id)

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
       sites: %{},
       connected: false,
       bandwidth_in: 0,
       bandwidth_out: 0
     )}
  end

  def connected_mount(_params, _session, socket) do
    supervisor_id = socket.assigns.supervisor_id
    RSMP.Supervisors.ensure_supervisor(supervisor_id)
    Phoenix.PubSub.subscribe(RSMP.PubSub, "supervisor:#{supervisor_id}")
    connected = RSMP.Supervisor.connected?(supervisor_id)
    schedule_bandwidth_tick()
    {:ok, sort_sites(assign(socket, connected: connected, bandwidth_in: 0, bandwidth_out: 0, prev_stats: nil))}
  end

  def sort_sites(socket) do
    supervisor_id = socket.assigns.supervisor_id

    assign(socket,
      sites:
        RSMP.Supervisor.sites(supervisor_id)
        |> Map.to_list()
        |> Enum.sort_by(fn {id, state} ->
          priority = case state.presence do
            "online" -> 0
            "offline" -> 1
            "shutdown" -> 2
            _ -> 3
          end
          {priority, id}
        end, :asc)
    )
  end

  @impl true
  def handle_event("toggle_connection", _params, socket) do
    RSMP.Supervisor.toggle_connection(socket.assigns.supervisor_id)
    {:noreply, socket}
  end

  @impl true
  def handle_event(name, data, socket) do
    Logger.info("unhandled event: #{inspect([name, data])}")
    {:noreply, socket}
  end

  @impl true
  def handle_info(%{topic: "connected", connected: connected}, socket) do
    {:noreply, assign(socket, connected: connected)}
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
  def handle_info(%{topic: "presence"}, socket) do
    {:noreply, sort_sites(socket)}
  end

  @impl true
  def handle_info(%{topic: "alarm"}, socket) do
    {:noreply, sort_sites(socket)}
  end

  @impl true
  def handle_info(:tick_bandwidth, socket) do
    schedule_bandwidth_tick()
    supervisor_id = socket.assigns.supervisor_id

    socket =
      try do
        case RSMP.Connection.get_socket_stats(supervisor_id) do
          {:ok, %{recv: recv, send: snd}} ->
            prev = socket.assigns.prev_stats

            if prev do
              assign(socket,
                bandwidth_in: recv - prev.recv,
                bandwidth_out: snd - prev.send,
                prev_stats: %{recv: recv, send: snd}
              )
            else
              assign(socket, prev_stats: %{recv: recv, send: snd})
            end

          _ ->
            assign(socket, bandwidth_in: 0, bandwidth_out: 0, prev_stats: nil)
        end
      rescue
        _ -> assign(socket, bandwidth_in: 0, bandwidth_out: 0, prev_stats: nil)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info(%{topic: topic} = data, socket) do
    Logger.info("unhandled info x: #{inspect([topic, data])}")
    {:noreply, socket}
  end

  defp schedule_bandwidth_tick do
    Process.send_after(self(), :tick_bandwidth, 1000)
  end

  def format_bandwidth(bytes) when bytes >= 1_000_000 do
    "#{Float.round(bytes / 1_000_000, 1)} MB/s"
  end

  def format_bandwidth(bytes) when bytes >= 1_000 do
    "#{Float.round(bytes / 1000, 1)} kB/s"
  end

  def format_bandwidth(bytes) do
    "#{bytes} B/s"
  end
end
