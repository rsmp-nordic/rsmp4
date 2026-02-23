defmodule RSMP.Site.Web.SiteLive.Site do
  use RSMP.Site.Web, :live_view
  alias RSMP.Site
  alias RSMP.Node.TLC
  @channel_glow_ms 500

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
       channel_list: [],
       channels_by_status: %{},
       channel_pulses: %{},
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
    channel_list = TLC.get_channels(site_id)
    mqtt_connected = try do
      RSMP.Connection.connected?(site_id)
    rescue
      _ -> false
    end

    schedule_volume_tick()
    schedule_groups_tick()

    {:ok,
     assign(socket,
       id: site_id,
       connected: mqtt_connected,
       removed: false,
       statuses: statuses,
       alarms: alarm_map(alarms),
       channel_list: channel_list,
       channels_by_status: channels_by_status(channel_list),
       channel_pulses: %{},
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
  def handle_event("start_channel", %{"module" => module, "code" => code, "channel" => channel_name}, socket) do
    site_id = socket.assigns[:id]
    channel_name = if channel_name == "", do: nil, else: channel_name
    TLC.start_channel(site_id, module, code, channel_name)
    channel_list = TLC.get_channels(site_id)

    channel_key = channel_identity(module, code, channel_name)

    socket =
      assign(socket, channel_list: channel_list, channels_by_status: channels_by_status(channel_list))

    socket =
      if Enum.any?(channel_list, fn channel -> channel_identity(channel) == channel_key and channel.running end) do
        pulse_channel(socket, channel_key)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("stop_channel", %{"module" => module, "code" => code, "channel" => channel_name}, socket) do
    site_id = socket.assigns[:id]
    channel_name = if channel_name == "", do: nil, else: channel_name
    TLC.stop_channel(site_id, module, code, channel_name)
    channel_list = TLC.get_channels(site_id)
    {:noreply, assign(socket, channel_list: channel_list, channels_by_status: channels_by_status(channel_list))}
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
    socket = assign_statuses_and_channels(socket, statuses, site_id)
    {:noreply, socket}
  end

  @impl true
  def handle_info(:tick_volume, socket) do
    schedule_volume_tick()
    {:noreply, push_volume_history(socket)}
  end

  @impl true
  def handle_info(:tick_groups, socket) do
    schedule_groups_tick()
    {:noreply, push_groups_history(socket)}
  end

  @impl true
  def handle_info(%{topic: "local_status"}, socket) do
    site_id = socket.assigns.id
    statuses = TLC.get_statuses(site_id)
    {:noreply, assign_statuses_and_channels(socket, statuses, site_id)}
  end

  @impl true
  def handle_info(%{topic: "status", changes: _changes}, socket) do
    site_id = socket.assigns.id
    statuses = TLC.get_statuses(site_id)
    {:noreply, assign_statuses_and_channels(socket, statuses, site_id)}
  end

  @impl true
  def handle_info(%{topic: "status", status: _status_payload}, socket) do
    site_id = socket.assigns.id
    statuses = TLC.get_statuses(site_id)
    {:noreply, assign_statuses_and_channels(socket, statuses, site_id)}
  end

  @impl true
  def handle_info(%{topic: "status"}, socket) do
    site_id = socket.assigns.id
    statuses = TLC.get_statuses(site_id)
    {:noreply, assign_statuses_and_channels(socket, statuses, site_id)}
  end

  @impl true
  def handle_info(%{topic: "channel_data", channel: channel_key}, socket) when is_binary(channel_key) do
    {:noreply, pulse_channel(socket, channel_key)}
  end

  @impl true
  def handle_info({:clear_channel_pulse, channel_key}, socket) do
    {:noreply, update(socket, :channel_pulses, &Map.delete(&1, channel_key))}
  end

  @impl true
  def handle_info(%{topic: "channel"}, socket) do
    site_id = socket.assigns.id
    channel_list = TLC.get_channels(site_id)
    {:noreply, assign(socket, channel_list: channel_list, channels_by_status: channels_by_status(channel_list))}
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

  def channels_by_status(channel_list) do
    Enum.group_by(channel_list, fn channel -> "#{channel.module}.#{channel.code}" end)
  end

  def format_status_lines(value) when is_map(value) do
    value
    |> Enum.map(fn {key, val} -> {to_string(key), val} end)
    |> Enum.sort()
  end

  def format_status_lines(value), do: [{"value", value}]

  def format_status_value(value) when is_map(value) or is_list(value), do: Poison.encode!(value)
  def format_status_value(value), do: to_string(value)

  def channel_button_class(channel, channel_pulses) do
    class = RSMP.ButtonClasses.channel(channel.running)

    if Map.get(channel_pulses, channel_identity(channel), false) do
      class <> " animate-channel-glow"
    else
      class
    end
  end

  defp assign_statuses_and_channels(socket, statuses, site_id) do
    channel_list = TLC.get_channels(site_id)

    assign(socket,
      statuses: statuses,
      channel_list: channel_list,
      channels_by_status: channels_by_status(channel_list)
    )
  end

  defp pulse_channel(socket, channel_key) do
    Process.send_after(self(), {:clear_channel_pulse, channel_key}, @channel_glow_ms)
    update(socket, :channel_pulses, &Map.put(&1, channel_key, true))
  end

  defp channel_identity(%{module: module, code: code} = channel) do
    channel_name = Map.get(channel, :channel_name) || Map.get(channel, "channel_name")
    channel_identity(module, code, channel_name)
  end

  defp channel_identity(module, code, channel_name) do
    normalized_channel = if channel_name in [nil, ""], do: "default", else: channel_name
    "#{module}.#{code}/#{normalized_channel}"
  end

  # Schedule tick aligned to the next wall-clock second boundary so that
  # site and supervisor charts aggregate over identical time windows.
  defp schedule_volume_tick do
    now_ms = System.system_time(:millisecond)
    delay = 1000 - rem(now_ms, 1000)
    Process.send_after(self(), :tick_volume, delay)
  end

  defp schedule_groups_tick do
    now_ms = System.system_time(:millisecond)
    delay = 1000 - rem(now_ms, 1000)
    Process.send_after(self(), :tick_groups, delay)
  end

  defp push_volume_history(socket) do
    if connected?(socket) do
      points = TLC.get_volume_data_points(socket.assigns.id)
      bins = RSMP.Remote.Node.Site.aggregate_into_bins(points, 60)
      push_event(socket, "volume_history", %{bins: bins})
    else
      socket
    end
  end

  defp push_groups_history(socket) do
    if connected?(socket) do
      history = TLC.get_groups_history(socket.assigns.id)
      now_ms = System.system_time(:millisecond)
      window_start = now_ms - 60_000

      # Filter to the last 60 seconds, but include the last entry before the window
      # so we know the initial state at the start of the window
      filtered =
        case Enum.split_while(history, fn p -> p.ts < window_start end) do
          {[], within} -> within
          {before, within} -> [List.last(before) | within]
        end

      push_event(socket, "groups_history", %{history: filtered})
    else
      socket
    end
  end

end
