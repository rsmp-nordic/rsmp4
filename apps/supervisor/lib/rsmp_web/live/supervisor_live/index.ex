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
       clients: %{}
     )}
  end

  def connected_mount(_params, _session, socket) do
    Phoenix.PubSub.subscribe(RSMP.PubSub, "rsmp")
    clients = RSMP.Supervisor.clients()

    {:ok,
     assign(socket,
       clients: sort_clients(clients)
     )}
  end

  def sort_clients(clients) do
    clients
    |> Map.to_list()
    |> Enum.sort_by(fn {id, state} -> {state.online == false, id} end, :asc)
  end

  @impl true
  def handle_event(
        "alarm",
        %{"client-id" => client_id, "path" => path, "flag" => flag, "value" => value},
        socket
      ) do
    RSMP.Supervisor.set_alarm_flag(
      client_id,
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
  def handle_info(%{topic: "clients", clients: clients}, socket) do
    {:noreply, assign(socket, clients: sort_clients(clients))}
  end

  @impl true
  def handle_info(%{topic: "status", clients: clients}, socket) do
    {:noreply, assign(socket, clients: sort_clients(clients))}
  end

  @impl true
  def handle_info(%{topic: "alarm", clients: clients}, socket) do
    {:noreply, assign(socket, clients: sort_clients(clients))}
  end

  @impl true
  def handle_info(%{topic: topic} = data, socket) do
    Logger.info("unhandled info: #{inspect([topic, data])}")
    {:noreply, socket}
  end

  @impl true
  def handle_info(%{topic: "alarm", id: _id, path: _path, alarm: _alarm}, socket) do
    clients = RSMP.Supervisor.clients() |> sort_clients()

    {:noreply, assign(socket, clients: clients)}
  end
end
