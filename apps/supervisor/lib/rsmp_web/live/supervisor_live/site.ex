defmodule RSMP.Supervisor.Web.SupervisorLive.Site do
  use RSMP.Supervisor.Web, :live_view
  use Phoenix.Component

  require Logger

  @impl true
  def mount(params, _session, socket) do
    # note that mount is called twice, once for the html request,
    # then for the liveview websocket connection
    if connected?(socket) do
      Phoenix.PubSub.subscribe(RSMP.PubSub, "rsmp")
    end

    site_id = params["site_id"]
    site = RSMP.Supervisor.site(site_id)

    {:ok,
     assign(socket,
       site_id: site_id,
       site: site,
       alarm_flags: Enum.sort(["active", "acknowledged", "blocked"]),
       commands: ["tlc/2"],
       responses: %{}
     )}
  end

  def assign_client(socket) do
    site_id = socket.assigns.site_id
    site = RSMP.Supervisor.site(site_id)
    assign(socket, site: site)
  end

  # UI events

  @impl true
  def handle_event("alarm", %{"path" => path, "flag" => flag, "value" => value}, socket) do
    site_id = socket.assigns.site_id
    new_value = value == "false"

    RSMP.Supervisor.set_alarm_flag(site_id, path, flag, new_value)
    {:noreply, socket |> assign_client()}
  end

  @impl true
  def handle_event("command", %{"path" => path, "value" => plan}, socket) do
    plan = String.to_integer(plan)
    site_id = socket.assigns[:site_id]
    RSMP.Supervisor.set_plan(site_id, plan)
    Process.send_after(self(), {:command_waiting, path}, 1000)

    responses =
      socket.assigns.responses
      |> Map.put("tlc/2", %{"phase" => "sent"})

    {:noreply, assign(socket, responses: responses)}
  end

  @impl true
  def handle_event(name, data, socket) do
    Logger.info("unhandled event: #{inspect([name, data])}")
    {:noreply, socket}
  end

  # MQTT PubSub events

  @impl true
  def handle_info(%{topic: "status", clients: _clients}, socket) do
    {:noreply, socket |> assign_client()}
  end

  @impl true
  def handle_info(%{topic: "alarm", clients: _clients}, socket) do
    {:noreply, socket |> assign_client()}
  end

  @impl true
  def handle_info(%{topic: "alarm", path: _path, alarm: _alarm}, socket) do
    {:noreply, socket}
  end

  # Called 1s after we send a command.
  # If we still haven't received a responds, show a spinner
  @impl true
  def handle_info({:command_waiting, path}, socket) do
    if socket.assigns.responses[path]["phase"] == "sent" do
      responses =
        socket.assigns.responses
        |> Map.put("tlc/2", %{"phase" => "waiting"})

      {:noreply, assign(socket, responses: responses)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(%{topic: "response", response: response}, socket) do
    symbol =
      case response[:result]["status"] do
        "unknown" -> "⚠️ "
        "already" -> "ℹ️ "
        "ok" -> "✔️"
        _ -> ""
      end

    result =
      response[:result]
      |> Map.put("symbol", symbol)
      |> Map.put("phase", "received")

    responses =
      socket.assigns.responses
      |> Map.put("tlc/2", result)

    {:noreply, assign(socket, responses: responses)}
  end

  @impl true
  def handle_info(data, socket) do
    IO.puts("unhandled handle_info: #{inspect(data)}")
    {:noreply, socket}
  end
end
