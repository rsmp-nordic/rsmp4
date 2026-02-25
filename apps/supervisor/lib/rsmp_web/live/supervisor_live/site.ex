defmodule RSMP.Supervisor.Web.SupervisorLive.Site do
  use RSMP.Supervisor.Web, :live_view
  use Phoenix.Component
  require Logger
  @channel_glow_ms 500

  @impl true
  def mount(params, _session, socket) do
    # note that mount is called twice, once for the html request,
    # then for the liveview websocket connection
    supervisor_id = params["supervisor_id"]
    site_id = params["site_id"]

    if connected?(socket) do
      RSMP.Supervisors.ensure_supervisor(supervisor_id)
      Phoenix.PubSub.subscribe(RSMP.PubSub, "supervisor:#{supervisor_id}")
      Phoenix.PubSub.subscribe(RSMP.PubSub, "supervisor:#{supervisor_id}:#{site_id}")
    end

    connected =
      if connected?(socket) do
        RSMP.Supervisor.connected?(supervisor_id)
      else
        false
      end

    site =
      if connected?(socket) do
        RSMP.Supervisor.site(supervisor_id, site_id) || %{presence: "offline", statuses: %{}, channels: %{}, alarms: %{}}
      else
        %{presence: "offline", statuses: %{}, channels: %{}, alarms: %{}}
      end
    plan =
      get_in(site, [
        Access.key(:statuses, %{}),
        Access.key("tlc.plan", %{}),
        Access.key(:plan, 0)
      ])

    socket =
      assign(socket,
        supervisor_id: supervisor_id,
        site_id: site_id,
        connected: connected,
        site: site,
        channel_pulses: %{},
        plans: get_plans(site),
        alarm_flags: ["active"],
        has_volume_gaps: false,

        commands: %{
          "tlc.plan.set" => plan
        },
        responses: %{
          "tlc.plan.set" => %{"phase" => "idle", "symbol" => "", "reason" => ""}
        }
      )

    if connected?(socket) do
      schedule_volume_tick()
      schedule_groups_tick()
    end
    {:ok, socket |> push_volume_history() |> push_groups_history()}
  end

  def assign_site(socket) do
    supervisor_id = socket.assigns.supervisor_id
    site_id = socket.assigns.site_id
    site = RSMP.Supervisor.site(supervisor_id, site_id) || %{presence: "offline", statuses: %{}, channels: %{}, alarms: %{}}

    plan =
      get_in(site, [
        Access.key(:statuses, %{}),
        Access.key("tlc.plan", %{}),
        Access.key(:plan, 0)
      ])

    commands = Map.put(socket.assigns.commands, "tlc.plan.set", plan)

    assign(socket, site: site, plans: get_plans(site), commands: commands)
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
        |> Enum.map(fn {channel, number} -> {channel_label(channel), number} end)
        |> Enum.sort_by(fn {channel, _number} -> channel end)
        |> Enum.map_join("\n", fn {channel, number} -> "#{channel}: #{number}" end)

      seq ->
        "default: #{to_string(seq)}"
    end
  end

  def status_seq(_value), do: "-"

  def status_rows(site) do
    statuses = Map.get(site, :statuses, %{})
    channels = Map.get(site, :channels, %{})

    status_paths = Map.keys(statuses)

    channel_paths =
      channels
      |> Map.keys()
      |> Enum.map(&parse_channel_state_key/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn {path, _channel_key} -> path end)

    (status_paths ++ channel_paths)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn path ->
      value = Map.get(statuses, path)

      %{
        path: path,
        value: value,
        channels: status_channels(path, value, site)
      }
    end)
  end

  def status_channels(path, value, site) do
    seq_map = channel_seq_map(value)

    channel_keys =
      (Map.keys(seq_map) ++ channel_keys_from_state(site, path))
      |> Enum.uniq()
      |> Enum.sort()

    Enum.map(channel_keys, fn channel_key ->
      label = channel_label(channel_key)
      seq = Map.get(seq_map, channel_key)
      state = channel_state(site, path, channel_key)

      title =
        if is_nil(seq) do
          "Channel: #{label}\nState: #{state}"
        else
          "Channel: #{label}\nSeq: #{seq}\nState: #{state}"
        end

      %{
        key: channel_key,
        label: label,
        seq: seq,
        state: state,
        class: channel_state_class(state),
        title: title
      }
    end)
  end

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

  defp channel_label(channel) do
    case channel do
      nil -> "default"
      "" -> "default"
      _ -> to_string(channel)
    end
  end

  defp normalize_channel_key(channel) do
    case channel do
      nil -> "default"
      "" -> "default"
      other -> to_string(other)
    end
  end

  defp channel_seq_map(value) when is_map(value) do
    case Map.get(value, "seq") || Map.get(value, :seq) do
      seq when is_map(seq) ->
        Enum.into(seq, %{}, fn {channel, number} -> {normalize_channel_key(channel), number} end)

      nil ->
        %{}

      seq ->
        %{"default" => seq}
    end
  end

  defp channel_seq_map(_value), do: %{}

  defp channel_keys_from_state(site, path) do
    channels = Map.get(site, :channels, %{})

    channels
    |> Map.keys()
    |> Enum.map(&parse_channel_state_key/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(fn {channel_path, _channel_key} -> channel_path == path end)
    |> Enum.map(fn {_channel_path, channel_key} -> channel_key end)
  end

  defp parse_channel_state_key(key) when is_binary(key) do
    case String.split(key, "/") do
      [_channel_only] ->
        nil

      parts ->
        channel_key = List.last(parts)

        path =
          parts
          |> Enum.slice(0, length(parts) - 1)
          |> Enum.join("/")

        {path, channel_key}
    end
  end

  defp parse_channel_state_key(_), do: nil

  defp channel_state(site, path, channel_key) do
    channels = Map.get(site, :channels, %{})
    Map.get(channels, "#{path}/#{channel_key}", "stopped")
  end

  defp channel_state_class("running"), do: RSMP.ButtonClasses.channel(true)
  defp channel_state_class(_), do: RSMP.ButtonClasses.channel(false)

  def channel_button_class(channel, path, channel_pulses) do
    class = channel_state_class(channel.state)
    channel_key = channel_state_key(path, channel.key)

    if Map.get(channel_pulses, channel_key, false) do
      class <> " animate-channel-glow"
    else
      class
    end
  end

  def format_status_lines(value) do
    value
    |> status_value()
    |> do_format_status_lines()
  end

  defp do_format_status_lines(value) when is_map(value) do
    value
    |> Enum.map(fn {key, val} -> {to_string(key), val} end)
    |> Enum.sort()
  end

  defp do_format_status_lines(nil), do: []

  defp do_format_status_lines(value), do: [{"value", value}]

  def format_status_line_value(value) when is_map(value) or is_list(value), do: Poison.encode!(value)
  def format_status_line_value(value), do: to_string(value)

  # UI events

  @impl true
  def handle_event("toggle_connection", _params, socket) do
    RSMP.Supervisor.toggle_connection(socket.assigns.supervisor_id)
    {:noreply, socket}
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

    supervisor_id = socket.assigns.supervisor_id
    site_id = socket.assigns[:site_id]
    RSMP.Supervisor.set_plan(supervisor_id, site_id, plan)
    Process.send_after(self(), {:command_waiting, path}, 1000)

    responses =
      socket.assigns.responses
      |> Map.put("tlc.plan.set", %{"phase" => "sent"})

    {:noreply, assign(socket, responses: responses)}
  end

  @impl true
  def handle_event("throttle", %{"path" => path, "channel" => channel_name, "state" => state}, socket) do
    supervisor_id = socket.assigns.supervisor_id
    site_id = socket.assigns.site_id
    channel_state_key = channel_state_key(path, channel_name)

    case String.split(path, "/", parts: 2) do
      [code | _rest] ->
        channel =
          case channel_name do
            "" -> nil
            "default" -> nil
            value -> value
          end

        if state == "running" do
          RSMP.Supervisor.stop_channel(supervisor_id, site_id, code, channel)
        else
          RSMP.Supervisor.start_channel(supervisor_id, site_id, code, channel)
        end

      _ ->
        Logger.warning("Invalid channel path for throttle: #{path}")
    end

    socket =
      if state == "running" do
        socket
      else
        pulse_channel(socket, channel_state_key)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("fetch_missing", _params, socket) do
    supervisor_id = socket.assigns.supervisor_id
    site_id = socket.assigns.site_id

    # Get gap time ranges and send a fetch for each
    time_ranges = RSMP.Supervisor.gap_time_ranges(supervisor_id, site_id, "traffic.volume/live")

    for {from_ts, to_ts} <- time_ranges do
      RSMP.Supervisor.send_fetch(supervisor_id, site_id, "traffic.volume", "live", from_ts, to_ts)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event(name, data, socket) do
    Logger.info("unhandled event: #{inspect([name, data])}")
    {:noreply, socket}
  end

  # MQTT PubSub events

  # Data points are stored in the supervisor GenServer automatically.
  # The 1-second volume tick picks them up — no per-message push needed.
  @impl true
  def handle_info(%{topic: "data_point"}, socket) do
    {:noreply, socket}
  end

  # Server-driven 1-second tick: push the full bin array to the JS chart.
  # This is the single clock driving the graph — no JS-side timer.
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
  def handle_info(%{topic: "connected", connected: connected}, socket) do
    {:noreply, assign(socket, connected: connected)}
  end

  @impl true
  def handle_info(%{topic: "status", status: _status_payload}, socket) do
    {:noreply, socket |> assign_site()}
  end

  @impl true
  def handle_info(%{topic: "status"}, socket) do
    {:noreply, socket |> assign_site()}
  end

  @impl true
  def handle_info(%{topic: "local_status", status: _status_payload}, socket) do
    {:noreply, socket |> assign_site()}
  end

  @impl true
  def handle_info(%{topic: "local_status"}, socket) do
    {:noreply, socket |> assign_site()}
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
  def handle_info(%{topic: "presence"}, socket) do
    {:noreply, socket |> assign_site()}
  end

  @impl true
  def handle_info(%{topic: "replay"}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(%{topic: "channel"}, socket) do
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
    if response[:command] != "tlc.plan.set" do
      {:noreply, socket}
    else
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

  defp pulse_channel(socket, channel_key) do
    Process.send_after(self(), {:clear_channel_pulse, channel_key}, @channel_glow_ms)
    update(socket, :channel_pulses, &Map.put(&1, channel_key, true))
  end

  defp channel_state_key(path, channel_key) do
    "#{path}/#{normalize_channel_key(channel_key)}"
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

  # Fetch stored traffic.volume/live data points from the supervisor, aggregate
  # them into 1-second bins (oldest first), and push a volume_history event so
  # the JS chart renders the current state.
  defp push_volume_history(socket) do
    if connected?(socket) do
      supervisor_id = socket.assigns.supervisor_id
      site_id = socket.assigns.site_id
      points = RSMP.Supervisor.data_points(supervisor_id, site_id, "traffic.volume/live")
      seq_gaps = RSMP.Supervisor.gap_time_ranges(supervisor_id, site_id, "traffic.volume/live")
      next_ts_gaps = RSMP.Remote.Node.Site.next_ts_gap_ranges(points)
      all_gaps = seq_gaps ++ next_ts_gaps
      bins = RSMP.Remote.Node.Site.aggregate_into_bins_with_gaps(points, 60, all_gaps)
      has_gaps = all_gaps != []

      socket
      |> push_event("volume_history", %{bins: bins})
      |> assign(:has_volume_gaps, has_gaps)
    else
      socket
    end
  end

  # Build groups timeline from stored data points.
  # Data points are deltas (only changed groups). We replay them forward
  # to reconstruct full group snapshots at each timestamp.
  #
  # Each data point has a next_ts field (from replay/history) or none (live).
  # Gaps are implicit: any time discontinuity between a point's end time
  # and the next point's start time renders as grey. No gap markers needed.
  defp push_groups_history(socket) do
    if connected?(socket) do
      supervisor_id = socket.assigns.supervisor_id
      site_id = socket.assigns.site_id
      keyed_points = RSMP.Supervisor.data_points_with_keys(supervisor_id, site_id, "tlc.groups/live")

      # Replay deltas to build full snapshots
      {history, _state} =
        Enum.reduce(keyed_points, {[], %{}}, fn {_key, point}, {history, state} ->
          groups_delta = get_groups_from_point(point.values)
          state = Map.merge(state, groups_delta)
          ts = DateTime.to_unix(point.ts, :millisecond)
          next_ts =
            case point[:next_ts] do
              %DateTime{} = dt -> DateTime.to_unix(dt, :millisecond)
              _ -> nil
            end

          {history ++ [%{ts: ts, next_ts: next_ts, groups: state}], state}
        end)

      # Filter to the last 60 seconds, keeping the last entry before the window
      now = DateTime.utc_now()
      window_start = DateTime.add(now, -60, :second)
      window_start_ms = DateTime.to_unix(window_start, :millisecond)
      filtered =
        case Enum.split_while(history, fn p -> p.ts < window_start_ms end) do
          {[], within} -> within
          {before, within} -> [List.last(before) | within]
        end

      push_event(socket, "groups_history", %{history: filtered})
    else
      socket
    end
  end

  defp get_groups_from_point(values) do
    cond do
      is_map(values[:groups]) -> values[:groups]
      is_map(values["groups"]) -> values["groups"]
      is_map(values[:signalgroupstatus]) -> values[:signalgroupstatus]
      is_map(values["signalgroupstatus"]) -> values["signalgroupstatus"]
      true -> %{}
    end
  end
end
