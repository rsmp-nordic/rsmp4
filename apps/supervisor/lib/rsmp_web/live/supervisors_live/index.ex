defmodule RSMP.Supervisor.Web.SupervisorsLive.Index do
  use RSMP.Supervisor.Web, :live_view
  use Phoenix.Component

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(RSMP.PubSub, "supervisors")
    end

    {:ok, assign(socket, supervisors: RSMP.Supervisors.list_supervisors())}
  end

  @impl true
  def handle_event("add_supervisor", _params, socket) do
    case RSMP.Supervisors.start_supervisor() do
      {:ok, _id} -> :ok
      {:error, reason} -> Logger.warning("Failed to start supervisor: #{inspect(reason)}")
    end

    {:noreply, assign(socket, supervisors: RSMP.Supervisors.list_supervisors())}
  end

  @impl true
  def handle_event("remove_supervisor", %{"id" => id}, socket) do
    RSMP.Supervisors.stop_supervisor(id)
    {:noreply, assign(socket, supervisors: RSMP.Supervisors.list_supervisors())}
  end

  @impl true
  def handle_info(%{topic: "supervisors_changed"}, socket) do
    {:noreply, assign(socket, supervisors: RSMP.Supervisors.list_supervisors())}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end
end
