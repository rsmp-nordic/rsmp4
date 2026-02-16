defmodule RSMP.Supervisor.Web.SupervisorLive.Site do
  use RSMP.Supervisor.Web, :live_view
  use Phoenix.Component
  require Logger

  @impl true
  def mount(params, _session, socket) do
    # note that mount is called twice, once for the html request,
    # then for the liveview websocket connection
    site_id = params["site_id"]

    if connected?(socket) do
      Phoenix.PubSub.subscribe(RSMP.PubSub, "supervisor:#{site_id}")
    end

    site = RSMP.Supervisor.site(site_id) || %{statuses: %{}, alarms: %{}}
    plan =
      get_in(site, [
        Access.key(:statuses, %{}),
        Access.key("tlc.plan", %{}),
        Access.key(:plan, 0)
      ])

    {:ok,
     assign(socket,
       site_id: site_id,
       site: site,
       plans: get_plans(site),
       alarm_flags: Enum.sort(["active", "acknowledged", "blocked"]),
       commands: %{
         "tlc.plan.set" => plan
       },
       responses: %{
         "tlc.plan.set" => %{"phase" => "idle", "symbol" => "", "reason" => ""}
       }
     )}
  end

  def assign_site(socket) do
    site_id = socket.assigns.site_id
    site = RSMP.Supervisor.site(site_id) || %{statuses: %{}, alarms: %{}}
    assign(socket, site: site, plans: get_plans(site))
  end

  defp get_plans(site) do
    case get_in(site, [Access.key(:statuses, %{}), Access.key("tlc.plans")]) do
      %{"value" => plans} when is_list(plans) -> Enum.sort(plans)
      %{value: plans} when is_list(plans) -> Enum.sort(plans)
      plans when is_list(plans) -> Enum.sort(plans)
      _ -> []
    end
  end

  def status_seq(value) when is_map(value) do
    case Map.get(value, "seq") || Map.get(value, :seq) do
      nil ->
        "-"

      seq when is_map(seq) ->
        seq
        |> Enum.map(fn {stream, number} -> {to_string(stream), number} end)
        |> Enum.sort_by(fn {stream, _number} -> stream end)
        |> Enum.map_join(", ", fn {stream, number} -> "\"#{stream}\": #{number}" end)
        |> then(fn body -> "{" <> body <> "}" end)

      seq ->
        to_string(seq)
    end
  end

  def status_seq(_value), do: "-"

  def status_value(value) when is_map(value) do
    cond do
      Map.has_key?(value, "value") ->
        value["value"]

      Map.has_key?(value, :value) ->
        value[:value]

      true ->
        value
        |> Map.delete("seq")
        |> Map.delete(:seq)
    end
  end

  def status_value(value), do: value

  # UI events

  @impl true
  def handle_event("alarm", %{"path" => path, "flag" => flag, "value" => value}, socket) do
    site_id = socket.assigns.site_id
    new_value = value == "false"

    RSMP.Supervisor.set_alarm_flag(site_id, RSMP.Path.from_string(path), flag, new_value)
    {:noreply, socket |> assign_site()}
  end

  @impl true
  def handle_event("command", params, socket) do
    path = params["path"]
    plan = params["plan"] || params["value"]
    plan =
      if is_integer(plan) do
        plan
      else
        String.to_integer(plan)
      end

    site_id = socket.assigns[:site_id]
    RSMP.Supervisor.set_plan(site_id, plan)
    Process.send_after(self(), {:command_waiting, path}, 1000)

    responses =
      socket.assigns.responses
      |> Map.put("tlc.plan.set", %{"phase" => "sent"})

    {:noreply, assign(socket, responses: responses)}
  end

  @impl true
  def handle_event(name, data, socket) do
    Logger.info("unhandled event: #{inspect([name, data])}")
    {:noreply, socket}
  end

  # MQTT PubSub events

  @impl true
  def handle_info(%{topic: "status"}, socket) do
    {:noreply, socket |> assign_site()}
  end

  @impl true
  def handle_info(%{topic: "local_status"}, socket) do
    {:noreply, socket |> assign_site()}
  end

  @impl true
  def handle_info(%{topic: "presence"}, socket) do
    {:noreply, socket |> assign_site()}
  end

  @impl true
  def handle_info(%{topic: "alarm", alarm: alarm}, socket) do
    Logger.info("Supervisor LiveView received alarm update: #{inspect(alarm)}")
    {:noreply, socket |> assign_site()}
  end

  # Called 1s after we send a command.
  # If we still haven't received a responds, show a spinner
  @impl true
  def handle_info({:command_waiting, path}, socket) do
    response = Map.get(socket.assigns.responses, path, %{})

    if response["phase"] == "sent" do
      responses =
        socket.assigns.responses
        |> Map.put("tlc.plan.set", %{"phase" => "waiting"})

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

    responses = socket.assigns.responses |> Map.put("tlc.plan.set", result)
    commands = socket.assigns.commands |> Map.put("tlc.plan.set", response[:result]["plan"])
    {:noreply, assign(socket, responses: responses, commands: commands)}
  end

  @impl true
  def handle_info(%{topic: "command_log", id: _id, message: _message}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(data, socket) do
    Logger.warning("unhandled info: #{inspect(data)}")
    {:noreply, socket}
  end
end
