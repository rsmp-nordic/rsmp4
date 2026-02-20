defmodule RSMP.Supervisor.Web.SupervisorLive.Site do
  use RSMP.Supervisor.Web, :live_view
  use Phoenix.Component
  require Logger
  @stream_glow_ms 500

  @impl true
  def mount(params, _session, socket) do
    # note that mount is called twice, once for the html request,
    # then for the liveview websocket connection
    supervisor_id = params["supervisor_id"]
    site_id = params["site_id"]

    if connected?(socket) do
      RSMP.Supervisors.ensure_supervisor(supervisor_id)
      Phoenix.PubSub.subscribe(RSMP.PubSub, "supervisor:#{supervisor_id}:#{site_id}")
    end

    site =
      if connected?(socket) do
        RSMP.Supervisor.site(supervisor_id, site_id) || %{presence: "offline", statuses: %{}, streams: %{}, alarms: %{}}
      else
        %{presence: "offline", statuses: %{}, streams: %{}, alarms: %{}}
      end
    plan =
      get_in(site, [
        Access.key(:statuses, %{}),
        Access.key("tlc.plan", %{}),
        Access.key(:plan, 0)
      ])

    {:ok,
     assign(socket,
       supervisor_id: supervisor_id,
       site_id: site_id,
       site: site,
       stream_pulses: %{},
       plans: get_plans(site),
       alarm_flags: ["active"],
       volume_points: [],
       commands: %{
         "tlc.plan.set" => plan
       },
       responses: %{
         "tlc.plan.set" => %{"phase" => "idle", "symbol" => "", "reason" => ""}
       }
     )}
  end

  def assign_site(socket) do
    supervisor_id = socket.assigns.supervisor_id
    site_id = socket.assigns.site_id
    site = RSMP.Supervisor.site(supervisor_id, site_id) || %{presence: "offline", statuses: %{}, streams: %{}, alarms: %{}}

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
        |> Enum.map(fn {stream, number} -> {stream_label(stream), number} end)
        |> Enum.sort_by(fn {stream, _number} -> stream end)
        |> Enum.map_join("\n", fn {stream, number} -> "#{stream}: #{number}" end)

      seq ->
        "default: #{to_string(seq)}"
    end
  end

  def status_seq(_value), do: "-"

  def status_rows(site) do
    statuses = Map.get(site, :statuses, %{})
    streams = Map.get(site, :streams, %{})

    status_paths = Map.keys(statuses)

    stream_paths =
      streams
      |> Map.keys()
      |> Enum.map(&parse_stream_state_key/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn {path, _stream_key} -> path end)

    (status_paths ++ stream_paths)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn path ->
      value = Map.get(statuses, path)

      %{
        path: path,
        value: value,
        streams: status_streams(path, value, site)
      }
    end)
  end

  def status_streams(path, value, site) do
    seq_map = stream_seq_map(value)

    stream_keys =
      (Map.keys(seq_map) ++ stream_keys_from_state(site, path))
      |> Enum.uniq()
      |> Enum.sort()

    Enum.map(stream_keys, fn stream_key ->
      label = stream_label(stream_key)
      seq = Map.get(seq_map, stream_key)
      state = stream_state(site, path, stream_key)

      title =
        if is_nil(seq) do
          "Stream: #{label}\nState: #{state}"
        else
          "Stream: #{label}\nSeq: #{seq}\nState: #{state}"
        end

      %{
        key: stream_key,
        label: label,
        seq: seq,
        state: state,
        class: stream_state_class(state),
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

  defp stream_label(stream) do
    case stream do
      nil -> "default"
      "" -> "default"
      _ -> to_string(stream)
    end
  end

  defp normalize_stream_key(stream) do
    case stream do
      nil -> "default"
      "" -> "default"
      other -> to_string(other)
    end
  end

  defp stream_seq_map(value) when is_map(value) do
    case Map.get(value, "seq") || Map.get(value, :seq) do
      seq when is_map(seq) ->
        Enum.into(seq, %{}, fn {stream, number} -> {normalize_stream_key(stream), number} end)

      nil ->
        %{}

      seq ->
        %{"default" => seq}
    end
  end

  defp stream_seq_map(_value), do: %{}

  defp stream_keys_from_state(site, path) do
    streams = Map.get(site, :streams, %{})

    streams
    |> Map.keys()
    |> Enum.map(&parse_stream_state_key/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(fn {stream_path, _stream_key} -> stream_path == path end)
    |> Enum.map(fn {_stream_path, stream_key} -> stream_key end)
  end

  defp parse_stream_state_key(key) when is_binary(key) do
    case String.split(key, "/") do
      [_stream_only] ->
        nil

      parts ->
        stream_key = List.last(parts)

        path =
          parts
          |> Enum.slice(0, length(parts) - 1)
          |> Enum.join("/")

        {path, stream_key}
    end
  end

  defp parse_stream_state_key(_), do: nil

  defp stream_state(site, path, stream_key) do
    streams = Map.get(site, :streams, %{})
    Map.get(streams, "#{path}/#{stream_key}", "stopped")
  end

  defp stream_state_class("running"), do: RSMP.ButtonClasses.stream(true)
  defp stream_state_class(_), do: RSMP.ButtonClasses.stream(false)

  def stream_button_class(stream, path, stream_pulses) do
    class = stream_state_class(stream.state)
    stream_key = stream_state_key(path, stream.key)

    if Map.get(stream_pulses, stream_key, false) do
      class <> " animate-stream-glow"
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
  end

  defp do_format_status_lines(nil), do: []

  defp do_format_status_lines(value), do: [{"value", value}]

  def format_status_line_value(value) when is_map(value) or is_list(value), do: Poison.encode!(value)
  def format_status_line_value(value), do: to_string(value)

  # UI events

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
  def handle_event("throttle", %{"path" => path, "stream" => stream_name, "state" => state}, socket) do
    supervisor_id = socket.assigns.supervisor_id
    site_id = socket.assigns.site_id
    stream_state_key = stream_state_key(path, stream_name)

    case String.split(path, "/", parts: 2) do
      [full_code | _rest] ->
        case String.split(full_code, ".", parts: 2) do
          [module, code] ->
            stream =
              case stream_name do
                "" -> nil
                "default" -> nil
                value -> value
              end

            if state == "running" do
              RSMP.Supervisor.stop_stream(supervisor_id, site_id, module, code, stream)
            else
              RSMP.Supervisor.start_stream(supervisor_id, site_id, module, code, stream)
            end

          _ ->
            Logger.warning("Unable to parse stream path for throttle: #{path}")
        end

      _ ->
        Logger.warning("Invalid stream path for throttle: #{path}")
    end

    socket =
      if state == "running" do
        socket
      else
        pulse_stream(socket, stream_state_key)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event(name, data, socket) do
    Logger.info("unhandled event: #{inspect([name, data])}")
    {:noreply, socket}
  end

  # MQTT PubSub events

  @impl true
  def handle_info(%{topic: "data_point", path: "traffic.volume", stream: "live"} = msg, socket) do
    point = %{
      ts: msg.ts,
      cars: Map.get(msg.values, "cars", 0),
      bicycles: Map.get(msg.values, "bicycles", 0),
      busses: Map.get(msg.values, "busses", 0),
      seq: msg.seq,
      source: msg.source
    }
    volume_points = (socket.assigns.volume_points ++ [point]) |> Enum.take(-200)
    {:noreply, assign(socket, volume_points: volume_points)}
  end

  @impl true
  def handle_info(%{topic: "data_point"}, socket) do
    {:noreply, socket}
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
  def handle_info(%{topic: "stream_data", stream: stream_key}, socket) when is_binary(stream_key) do
    {:noreply, pulse_stream(socket, stream_key)}
  end

  @impl true
  def handle_info({:clear_stream_pulse, stream_key}, socket) do
    {:noreply, update(socket, :stream_pulses, &Map.delete(&1, stream_key))}
  end

  @impl true
  def handle_info(%{topic: "presence"}, socket) do
    {:noreply, socket |> assign_site()}
  end

  @impl true
  def handle_info(%{topic: "stream"}, socket) do
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
    if response[:command] != "plan.set" do
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

  defp pulse_stream(socket, stream_key) do
    Process.send_after(self(), {:clear_stream_pulse, stream_key}, @stream_glow_ms)
    update(socket, :stream_pulses, &Map.put(&1, stream_key, true))
  end

  defp stream_state_key(path, stream_key) do
    "#{path}/#{normalize_stream_key(stream_key)}"
  end

  # Volume graph rendering

  def render_volume_graph(assigns) do
    points = assigns.volume_points

    {svg_data, legend} =
      if length(points) < 2 do
        {nil, nil}
      else
        w = 600
        h = 80
        pad_x = 4
        pad_y = 4
        gap_threshold_ms = 15_000

        max_val =
          Enum.flat_map(points, fn p -> [p.cars, p.bicycles, p.busses] end)
          |> Enum.max(fn -> 1 end)
          |> max(1)

        first_ts = List.first(points).ts |> DateTime.to_unix(:millisecond)
        last_ts = List.last(points).ts |> DateTime.to_unix(:millisecond)
        time_span = max(last_ts - first_ts, 1)

        segments_by_key =
          Enum.map(
            [{"#60a5fa", :cars}, {"#4ade80", :bicycles}, {"#fb923c", :busses}],
            fn {color, key} ->
              segs = volume_graph_segments(points, key, first_ts, time_span, w, pad_x, h, pad_y, max_val, gap_threshold_ms)
              {color, segs}
            end
          )

        replay_dots =
          points
          |> Enum.filter(fn p -> p.source in [:replay, :history] end)
          |> Enum.map(fn p ->
            ts_ms = DateTime.to_unix(p.ts, :millisecond)
            cx = pad_x + trunc((ts_ms - first_ts) / time_span * (w - 2 * pad_x))
            {cx, pad_y + div(h, 2)}
          end)

        {{w, h, pad_y, segments_by_key, replay_dots, length(points)}, true}
      end

    assigns =
      Map.merge(assigns, %{
        svg_data: svg_data,
        legend: legend
      })

    ~H"""
    <%= if @svg_data == nil do %>
      <div class="text-gray-400 text-sm py-2">No volume data yet — set traffic level to generate data</div>
    <% else %>
      <% {w, h, pad_y, segments_by_key, replay_dots, num_points} = @svg_data %>
      <svg viewBox={"0 0 #{w} #{h + pad_y * 2}"} class="w-full rounded bg-stone-900" xmlns="http://www.w3.org/2000/svg">
        <%= for {color, segs} <- segments_by_key do %>
          <%= for seg <- segs do %>
            <polyline
              points={seg}
              fill="none"
              stroke={color}
              stroke-width="1.5"
              stroke-linejoin="round"
              stroke-linecap="round"
            />
          <% end %>
        <% end %>
        <%= for {cx, cy} <- replay_dots do %>
          <circle cx={cx} cy={cy} r="2" fill="#fbbf24" opacity="0.7" />
        <% end %>
      </svg>
      <div class="flex gap-4 text-xs mt-1">
        <span class="text-blue-400">&#9644; Cars</span>
        <span class="text-green-400">&#9644; Bicycles</span>
        <span class="text-orange-400">&#9644; Busses</span>
        <span class="text-yellow-400">&#9679; Replay/History</span>
        <span class="text-gray-400 ml-auto"><%= num_points %> points</span>
      </div>
    <% end %>
    """
  end

  defp volume_graph_segments(points, key, first_ts, time_span, w, pad_x, h, pad_y, max_val, gap_threshold_ms) do
    {segs, last_seg} =
      Enum.reduce(points, {[], []}, fn point, {segs, cur_seg} ->
        ts_ms = DateTime.to_unix(point.ts, :millisecond)

        case cur_seg do
          [] ->
            {segs, [point]}

          _ ->
            last_ts_ms = DateTime.to_unix(List.last(cur_seg).ts, :millisecond)

            if ts_ms - last_ts_ms > gap_threshold_ms do
              {segs ++ [cur_seg], [point]}
            else
              {segs, cur_seg ++ [point]}
            end
        end
      end)

    all_segs = if last_seg != [], do: segs ++ [last_seg], else: segs

    Enum.map(all_segs, fn seg ->
      seg
      |> Enum.map(fn point ->
        ts_ms = DateTime.to_unix(point.ts, :millisecond)
        cx = pad_x + (ts_ms - first_ts) / time_span * (w - 2 * pad_x)
        val = Map.get(point, key, 0)
        cy = pad_y + h - trunc(val / max_val * h)
        "#{trunc(cx)},#{cy}"
      end)
      |> Enum.join(" ")
    end)
  end
end
