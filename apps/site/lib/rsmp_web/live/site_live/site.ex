defmodule RSMP.Site.Web.SiteLive.Site do
  use RSMP.Site.Web, :live_view
  alias RSMP.Site
  alias RSMP.Node.TLC
  @stream_glow_ms 500

  @impl true
  def mount(params, session, socket) do
    case connected?(socket) do
      false ->
        initial_mount(params, session, socket)

      true ->
        connected_mount(params, session, socket)
    end
  end

  def initial_mount(params, _session, socket) do
    site_id = params["site_id"]

    {:ok,
     assign(socket,
       page: "loading",
       id: site_id,
       connected: false,
       removed: false,
       statuses: %{},
       alarms: %{},
       stream_list: [],
       streams_by_status: %{},
       stream_pulses: %{},
       traffic_level: :low,
       plan_result: %{"message" => ""},
       command_logs: [],
       alarm_flags: RSMP.Alarm.get_flag_keys()
     )}
  end

  def connected_mount(params, _session, socket) do
    site_id = params["site_id"]
    RSMP.Sites.ensure_site(site_id)
    Phoenix.PubSub.subscribe(RSMP.PubSub, "site:#{site_id}")
    Phoenix.PubSub.subscribe(RSMP.PubSub, "sites")

    statuses = TLC.get_statuses(site_id)
    alarms = TLC.get_alarms(site_id)
    stream_list = TLC.get_streams(site_id)
    mqtt_connected = try do
      RSMP.Connection.connected?(site_id)
    rescue
      _ -> false
    end

    {:ok,
     assign(socket,
       id: site_id,
       connected: mqtt_connected,
       removed: false,
       statuses: statuses,
       alarms: alarm_map(alarms),
       stream_list: stream_list,
       streams_by_status: streams_by_status(stream_list),
       stream_pulses: %{},
       traffic_level: TLC.get_traffic_level(site_id),
       plan_result: %{"message" => ""},
       command_logs: [],
       alarm_flags: RSMP.Alarm.get_flag_keys()
     )}
  end

  def change_status(data, socket, delta) do
    path = data["value"]
    pid = socket.assigns[:rsmp_site_id]
    statuses = Site.get_statuses(pid)
    new_value = statuses[path] + delta
    Site.set_status(pid, path, new_value)

    if path == "./env/temperature" do
      if new_value >= 30 do
        Site.raise_alarm(pid, path)
      else
        Site.clear_alarm(pid, path)
      end
    end

    if path == "./env/humidity" do
      if new_value >= 50 do
        Site.raise_alarm(pid, path)
      else
        Site.clear_alarm(pid, path)
      end
    end

    statuses = Site.get_statuses(pid)
    {:noreply, assign(socket, statuses: statuses)}
  end

  @impl true
  def handle_event(_name, _data, %{assigns: %{removed: true}} = socket) do
    {:noreply, socket}
  end

  def handle_event("toggle_connection", _params, socket) do
    site_id = socket.assigns[:id]

    if socket.assigns.connected do
      RSMP.Connection.simulate_disconnect(site_id)
    else
      RSMP.Connection.simulate_reconnect(site_id)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("set_plan", %{"plan" => plan}, socket) do
    site_id = socket.assigns[:id]
    plan = String.to_integer(plan)
    TLC.set_plan_local(site_id, plan)
    {:noreply, socket}
  end

  @impl true
  def handle_event("set_traffic_level", %{"level" => level}, socket) do
    site_id = socket.assigns[:id]

    traffic_level =
      case level do
        "none" -> :none
        "high" -> :high
        _ -> :low
      end

    TLC.set_traffic_level(site_id, traffic_level)
    {:noreply, assign(socket, traffic_level: traffic_level)}
  end

  @impl true
  def handle_event("start_stream", %{"module" => module, "code" => code, "stream" => stream_name}, socket) do
    site_id = socket.assigns[:id]
    stream_name = if stream_name == "", do: nil, else: stream_name
    TLC.start_stream(site_id, module, code, stream_name)
    stream_list = TLC.get_streams(site_id)

    stream_key = stream_identity(module, code, stream_name)

    socket =
      assign(socket, stream_list: stream_list, streams_by_status: streams_by_status(stream_list))

    socket =
      if Enum.any?(stream_list, fn stream -> stream_identity(stream) == stream_key and stream.running end) do
        pulse_stream(socket, stream_key)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("stop_stream", %{"module" => module, "code" => code, "stream" => stream_name}, socket) do
    site_id = socket.assigns[:id]
    stream_name = if stream_name == "", do: nil, else: stream_name
    TLC.stop_stream(site_id, module, code, stream_name)
    stream_list = TLC.get_streams(site_id)
    {:noreply, assign(socket, stream_list: stream_list, streams_by_status: streams_by_status(stream_list))}
  end

  @impl true
  def handle_event("alarm", data, socket) do
     path = data["path"]
     flag = data["value"]
     site_id = socket.assigns[:id]

     if flag == "active" do
       alarms = TLC.get_alarms(site_id)
       current_alarm = alarms[path]
       new_value = not Map.get(current_alarm, :active)
       TLC.set_alarm(site_id, path, %{flag => new_value})

       alarms = TLC.get_alarms(site_id)
       {:noreply, assign(socket, alarms: alarm_map(alarms))}
     else
       {:noreply, socket}
     end
  end

  @impl true
  def handle_event(_name, _data, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(%{topic: "sites_changed"}, socket) do
    site_id = socket.assigns.id
    if site_id not in RSMP.Sites.list_sites() do
      {:noreply, assign(socket, removed: true, connected: false)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(_msg, %{assigns: %{removed: true}} = socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(%{topic: "alarm"}, socket) do
    site_id = socket.assigns[:id]
    alarms = TLC.get_alarms(site_id)
    {:noreply, assign(socket, alarms: alarm_map(alarms))}
  end

  @impl true
  def handle_info(%{topic: "local_status", changes: _changes}, socket) do
    site_id = socket.assigns.id
    statuses = TLC.get_statuses(site_id)
    {:noreply, assign_statuses_and_streams(socket, statuses, site_id)}
  end

  @impl true
  def handle_info(%{topic: "local_status"}, socket) do
    site_id = socket.assigns.id
    statuses = TLC.get_statuses(site_id)
    {:noreply, assign_statuses_and_streams(socket, statuses, site_id)}
  end

  @impl true
  def handle_info(%{topic: "status", changes: _changes}, socket) do
    site_id = socket.assigns.id
    statuses = TLC.get_statuses(site_id)
    {:noreply, assign_statuses_and_streams(socket, statuses, site_id)}
  end

  @impl true
  def handle_info(%{topic: "status", status: _status_payload}, socket) do
    site_id = socket.assigns.id
    statuses = TLC.get_statuses(site_id)
    {:noreply, assign_statuses_and_streams(socket, statuses, site_id)}
  end

  @impl true
  def handle_info(%{topic: "status"}, socket) do
    site_id = socket.assigns.id
    statuses = TLC.get_statuses(site_id)
    {:noreply, assign_statuses_and_streams(socket, statuses, site_id)}
  end

  @impl true
  def handle_info(%{topic: "stream_data", stream: stream_key}, socket) when is_binary(stream_key) do
    {:noreply, pulse_stream(socket, stream_key)}
  end

  @impl true
  def handle_info({:clear_stream_pulse, stream_key}, socket) do
    {:noreply, update(socket, :stream_pulses, &Map.delete(&1, stream_key))}
  end

  @impl true
  def handle_info(%{topic: "stream"}, socket) do
    site_id = socket.assigns.id
    stream_list = TLC.get_streams(site_id)
    {:noreply, assign(socket, stream_list: stream_list, streams_by_status: streams_by_status(stream_list))}
  end

  @impl true
  def handle_info(%{topic: "connected", connected: connected}, socket) do
    {:noreply, assign(socket, connected: connected)}
  end

  @impl true
  def handle_info(%{topic: "presence"}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(%{topic: "command_log", id: id, message: message}, socket) do
    logs = socket.assigns.command_logs
    new_logs = logs ++ [%{id: id, message: message}]
    new_logs = if length(new_logs) > 5, do: Enum.drop(new_logs, length(new_logs) - 5), else: new_logs
    {:noreply, assign(socket, command_logs: new_logs)}
  end

  @impl true
  def handle_info(%{topic: "plan_result", result: result}, socket) when is_map(result) do
    message = to_string(result[:message] || result["message"] || "")
    plan_result = %{"message" => message}
    {:noreply, assign(socket, plan_result: plan_result)}
  end

  @impl true
  def handle_info(%{topic: "response", response: _response}, socket) do
    {:noreply, socket}
  end

  # Change tracking on assigns only works with simple data, we
  # cannot use functions to extract data in our templates.
  # Convert alarm structs to plain maps.
  def alarm_map(alarms) do
    alarms
    |> Enum.map(fn {path, alarm} -> {path, Map.from_struct(alarm)} end)
    |> Enum.into(%{})
  end

  def streams_by_status(stream_list) do
    Enum.group_by(stream_list, fn stream -> "#{stream.module}.#{stream.code}" end)
  end

  def format_status_lines(value) when is_map(value) do
    value
    |> Enum.map(fn {key, val} -> {to_string(key), val} end)
  end

  def format_status_lines(value), do: [{"value", value}]

  def format_status_value(value) when is_map(value) or is_list(value), do: Poison.encode!(value)
  def format_status_value(value), do: to_string(value)

  def stream_button_class(stream, stream_pulses) do
    class = RSMP.ButtonClasses.stream(stream.running)

    if Map.get(stream_pulses, stream_identity(stream), false) do
      class <> " animate-stream-glow"
    else
      class
    end
  end

  defp assign_statuses_and_streams(socket, statuses, site_id) do
    stream_list = TLC.get_streams(site_id)

    assign(socket,
      statuses: statuses,
      stream_list: stream_list,
      streams_by_status: streams_by_status(stream_list)
    )
  end

  defp pulse_stream(socket, stream_key) do
    Process.send_after(self(), {:clear_stream_pulse, stream_key}, @stream_glow_ms)
    update(socket, :stream_pulses, &Map.put(&1, stream_key, true))
  end

  defp stream_identity(%{module: module, code: code} = stream) do
    stream_name = Map.get(stream, :stream_name) || Map.get(stream, "stream_name")
    stream_identity(module, code, stream_name)
  end

  defp stream_identity(module, code, stream_name) do
    normalized_stream = if stream_name in [nil, ""], do: "default", else: stream_name
    "#{module}.#{code}/#{normalized_stream}"
  end

end
