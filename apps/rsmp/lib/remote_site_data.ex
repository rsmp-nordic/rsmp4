defmodule RSMP.Remote.SiteData do
  use GenServer
  require Logger

  @graph_window_seconds 60

  @gap_fetch_channels RSMP.Node.TLC.channel_configs()
    |> Enum.filter(fn config -> config.gap_fetch end)
    |> Enum.map(fn config -> {config.code, config.channel_name} end)

  defstruct(
    supervisor_id: nil,
    remote_id: nil,
    site: nil,
    pending_fetches: %{}
  )

  # Public API

  def start_link({supervisor_id, remote_id}) do
    start_link({supervisor_id, remote_id, "offline"})
  end

  def start_link({supervisor_id, remote_id, initial_presence}) do
    via = RSMP.Registry.via_site_data(supervisor_id, remote_id)
    GenServer.start_link(__MODULE__, {supervisor_id, remote_id, initial_presence}, name: via)
  end

  def get_state(supervisor_id, remote_id) do
    case RSMP.Registry.lookup_site_data(supervisor_id, remote_id) do
      [{pid, _}] -> GenServer.call(pid, :get_state)
      [] -> nil
    end
  end

  def data_points(supervisor_id, remote_id, channel_key) do
    case RSMP.Registry.lookup_site_data(supervisor_id, remote_id) do
      [{pid, _}] -> GenServer.call(pid, {:data_points, channel_key})
      [] -> []
    end
  end

  def data_points_with_keys(supervisor_id, remote_id, channel_key) do
    case RSMP.Registry.lookup_site_data(supervisor_id, remote_id) do
      [{pid, _}] -> GenServer.call(pid, {:data_points_with_keys, channel_key})
      [] -> []
    end
  end

  def gap_time_ranges(supervisor_id, remote_id, channel_key) do
    case RSMP.Registry.lookup_site_data(supervisor_id, remote_id) do
      [{pid, _}] -> GenServer.call(pid, {:gap_time_ranges, channel_key})
      [] -> []
    end
  end

  def set_plan(supervisor_id, remote_id, plan) do
    case RSMP.Registry.lookup_site_data(supervisor_id, remote_id) do
      [{pid, _}] -> GenServer.cast(pid, {:set_plan, plan})
      [] -> :ok
    end
  end

  def start_channel(supervisor_id, remote_id, code, channel_name) do
    case RSMP.Registry.lookup_site_data(supervisor_id, remote_id) do
      [{pid, _}] -> GenServer.cast(pid, {:throttle_channel, code, channel_name, "start"})
      [] -> :ok
    end
  end

  def stop_channel(supervisor_id, remote_id, code, channel_name) do
    case RSMP.Registry.lookup_site_data(supervisor_id, remote_id) do
      [{pid, _}] -> GenServer.cast(pid, {:throttle_channel, code, channel_name, "stop"})
      [] -> :ok
    end
  end

  def send_fetch(supervisor_id, remote_id, code, channel_name, from_ts, to_ts) do
    case RSMP.Registry.lookup_site_data(supervisor_id, remote_id) do
      [{pid, _}] -> GenServer.cast(pid, {:send_fetch, code, channel_name, from_ts, to_ts})
      [] -> :ok
    end
  end

  # GenServer callbacks

  @impl GenServer
  def init({supervisor_id, remote_id, initial_presence}) do
    site = RSMP.Remote.Node.Site.new(id: remote_id)
    site = %{site | presence: initial_presence}
    state = %__MODULE__{
      supervisor_id: supervisor_id,
      remote_id: remote_id,
      site: site,
      pending_fetches: %{}
    }
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:get_state, _from, state) do
    {:reply, state.site, state}
  end

  def handle_call({:data_points, channel_key}, _from, state) do
    points = RSMP.Remote.Node.Site.get_data_points(state.site, channel_key)
    {:reply, points, state}
  end

  def handle_call({:data_points_with_keys, channel_key}, _from, state) do
    points = RSMP.Remote.Node.Site.get_data_points_with_keys(state.site, channel_key)
    {:reply, points, state}
  end

  def handle_call({:gap_time_ranges, channel_key}, _from, state) do
    ranges = RSMP.Remote.Node.Site.gap_time_ranges(state.site, channel_key)
    {:reply, ranges, state}
  end

  @impl GenServer
  def handle_cast({:receive, type, topic, data, properties}, state) do
    state =
      case type do
        "status" -> receive_status(state, topic, data, properties)
        "alarm" -> receive_alarm(state, topic, data)
        "result" -> receive_result(state, topic, data, properties)
        "channel" -> receive_channel(state, topic, data)
        "replay" -> receive_replay(state, topic, data)
        "history" -> receive_history(state, topic, data, properties)
        _ -> state
      end
    {:noreply, state}
  end

  def handle_cast({:set_plan, plan}, state) do
    topic = RSMP.Topic.new(state.remote_id, "command", "tlc.plan.set")
    command_id = SecureRandom.hex(2)

    Logger.debug("RSMP: Sending 'tlc.plan.set' command #{command_id} to #{state.remote_id}: plan #{plan}")

    RSMP.Connection.publish_message(
      state.supervisor_id,
      topic,
      %{"plan" => plan},
      %{retain: true, qos: 1},
      %{command_id: command_id}
    )

    {:noreply, state}
  end

  def handle_cast({:throttle_channel, code, channel_name, action}, state) do
    channel_segment =
      case channel_name do
        nil -> nil
        "" -> nil
        value -> to_string(value)
      end

    topic = RSMP.Topic.new(state.remote_id, "throttle", code, channel_segment)

    Logger.debug("RSMP: Sending throttle #{action} for #{code}#{if channel_segment, do: "/#{channel_segment}", else: ""} to #{state.remote_id}")

    RSMP.Connection.publish_message(
      state.supervisor_id,
      topic,
      %{"action" => action},
      %{retain: false, qos: 1},
      %{}
    )

    {:noreply, state}
  end

  def handle_cast({:send_fetch, code, channel_name, from_ts, to_ts}, state) do
    state = do_send_fetch(state, code, channel_name, from_ts, to_ts)
    {:noreply, state}
  end

  def handle_cast({:presence_update, presence}, state) do
    previous_presence = state.site.presence
    site = %{state.site | presence: presence}
    state = %{state | site: site}

    state =
      if presence in ["offline", "shutdown"] && previous_presence == "online" do
        now = DateTime.utc_now()
        update_site(state, fn site ->
          Enum.reduce(@gap_fetch_channels, site, fn {code, channel_name}, acc ->
            channel_key = "#{code}/#{channel_name}"
            acc
            |> RSMP.Remote.Node.Site.stamp_next_ts_on_last(channel_key, now)
            |> Map.update!(:channels, &Map.delete(&1, channel_key))
          end)
        end)
      else
        state
      end

    {:noreply, state}
  end

  def handle_cast({:connection_state, connected}, state) do
    state =
      if connected do
        # Retained channel state messages will arrive and trigger fetch via receive_channel.
        state
      else
        now = DateTime.utc_now()
        update_site(state, fn site ->
          Enum.reduce(@gap_fetch_channels, site, fn {code, channel_name}, acc ->
            channel_key = "#{code}/#{channel_name}"
            acc
            |> RSMP.Remote.Node.Site.stamp_next_ts_on_last(channel_key, now)
            |> Map.update!(:channels, &Map.delete(&1, channel_key))
          end)
        end)
      end

    {:noreply, state}
  end

  # Status handling

  defp receive_status(state, topic, data, _properties) do
    if data == nil do
      state
    else
      entries = data["entries"] || []

      Enum.reduce(entries, state, fn entry, acc ->
        receive_status_entry(acc, topic, entry, false)
      end)
    end
  end

  defp receive_status_entry(state, topic, data, retain) do
    site = state.site
    path = topic.path

    {status_type, seq, values, event_ts} = extract_status_envelope(data, retain)

    status_key = to_string(path)
    new_status = RSMP.Remote.Node.Site.from_rsmp_status(site, path, values)
    current_status = get_in(site.statuses, [status_key]) || %{}

    primary_channel = topic.channel_name == nil or topic.channel_name == "live"

    status =
      if primary_channel do
        if status_type == "delta" do
          deep_merge_status(current_status, new_status)
        else
          new_status
        end
      else
        current_status
      end

    status = maybe_put_status_seq(status, current_status, topic.channel_name, seq)

    site = put_in(site.statuses[status_key], status)
    state = %{state | site: site}

    pub = %{topic: "status", site: state.remote_id, status: %{topic.path => status}}
    Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{state.supervisor_id}:#{state.remote_id}", pub)

    channel_key = channel_state_key(path, topic.channel_name)
    channel_pub = %{topic: "channel_data", site: state.remote_id, channel: channel_key}
    Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{state.supervisor_id}:#{state.remote_id}", channel_pub)

    if retain do
      state
    else
      point_ts = event_ts || DateTime.utc_now()
      point_pub = %{
        topic: "data_point",
        site: state.remote_id,
        path: status_key,
        channel: topic.channel_name,
        values: new_status,
        ts: point_ts,
        seq: seq,
        source: :live
      }
      Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{state.supervisor_id}:#{state.remote_id}", point_pub)

      channel_key = "#{status_key}/#{topic.channel_name}"
      update_site(state, fn site ->
        site
        |> RSMP.Remote.Node.Site.clear_next_ts_before(channel_key, point_ts)
        |> RSMP.Remote.Node.Site.store_data_point(channel_key, seq, point_ts, new_status)
      end)
    end
  end

  # Alarm handling

  defp receive_alarm(state, topic, data) do
    alarm = %{
      "active" => data["aSt"] == "Active"
    }

    path_string = to_string(topic.path)
    site = state.site
    alarms = site.alarms |> Map.put(path_string, alarm)
    site = %{site | alarms: alarms} |> set_site_num_alarms()
    state = %{state | site: site}

    pub = %{topic: "alarm", alarm: %{topic.path => alarm}}
    Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{state.supervisor_id}", pub)
    Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{state.supervisor_id}:#{state.remote_id}", pub)

    state
  end

  # Result handling

  defp receive_result(state, topic, result, properties) do
    command_id = properties[:"Correlation-Data"]
    Logger.debug("RSMP: #{topic.id}: Received result: #{topic.path}: #{inspect(result)}")

    pub = %{
      topic: "response",
      response: %{
        id: topic.id,
        command: topic.path.code,
        command_id: command_id,
        result: result
      }
    }

    Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{state.supervisor_id}:#{state.remote_id}", pub)

    state
  end

  # Channel state handling

  defp receive_channel(state, topic, data) when is_map(data) do
    channel_name =
      case topic.channel_name do
        name when is_binary(name) and name != "" -> name
        _ -> nil
      end

    channel_state = data["state"] || data[:state]

    cond do
      is_nil(channel_name) ->
        Logger.warning("RSMP: #{topic.id}: Ignoring channel state without channel name: #{inspect(topic)}")
        state

      channel_state not in ["running", "stopped"] ->
        Logger.warning("RSMP: #{topic.id}: Ignoring invalid channel state payload: #{inspect(data)}")
        state

      true ->
        site = state.site
        path = RSMP.Path.new(topic.path.code)
        channel_key = channel_state_key(path, channel_name)
        previous_state = get_in(site.channels, [channel_key])

        state =
          if channel_state == "stopped" do
            now = DateTime.utc_now()
            state = put_in(state.site.channel_stopped_at[channel_key], now)
            update_site(state, fn site ->
              RSMP.Remote.Node.Site.stamp_next_ts_on_last(site, channel_key, now)
            end)
          else
            state
          end

        state = put_in(state.site.channels[channel_key], channel_state)

        Logger.debug("RSMP: #{state.remote_id}: Received channel state #{channel_key}: #{channel_state}")

        pub = %{topic: "channel", site: state.remote_id, channel: channel_key, state: channel_state}
        Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{state.supervisor_id}:#{state.remote_id}", pub)

        if channel_state == "running" && previous_state in ["stopped", nil] do
          fallback_ts = DateTime.add(DateTime.utc_now(), -@graph_window_seconds, :second)

          case Enum.find(@gap_fetch_channels, fn {code, cn} ->
            "#{code}/#{cn}" == channel_key
          end) do
            {code, cn} -> fetch_channel_gaps(state, code, cn, fallback_ts)
            nil -> state
          end
        else
          state
        end
    end
  end

  defp receive_channel(state, _topic, nil), do: state

  defp receive_channel(state, topic, data) do
    Logger.warning("RSMP: #{topic.id}: Ignoring channel state payload: #{inspect(data)}")
    state
  end

  # Replay handling

  defp receive_replay(state, topic, data) when is_map(data) do
    entries = data["entries"] || []

    state =
      Enum.reduce(entries, state, fn entry, acc ->
        receive_replay_entry(acc, topic, entry)
      end)

    if data["done"] do
      handle_replay_done(state, topic)
    else
      state
    end
  end

  defp receive_replay(state, _topic, _data), do: state

  defp handle_replay_done(state, topic) do
    code = topic.path.code
    channel_name = topic.channel_name

    done_pub = %{topic: "replay", done: true, site: state.remote_id, path: to_string(topic.path), channel: channel_name}
    Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{state.supervisor_id}:#{state.remote_id}", done_pub)

    if Enum.member?(@gap_fetch_channels, {code, channel_name}) do
      fallback_from_ts = DateTime.add(DateTime.utc_now(), -@graph_window_seconds, :second)
      fetch_channel_gaps(state, code, channel_name, fallback_from_ts)
    else
      state
    end
  end

  defp receive_replay_entry(state, topic, data) when is_map(data) do
    site = state.site
    path = topic.path

    if data["values"] do
      ts = parse_iso8601(data["ts"]) || DateTime.utc_now()
      seq = data["seq"]
      values = RSMP.Remote.Node.Site.from_rsmp_status(site, path, data["values"])

      Logger.debug("RSMP: #{state.supervisor_id}: Received replay #{path}/#{topic.channel_name} seq=#{seq} values=#{inspect(values)}")

      point_pub = %{
        topic: "data_point",
        site: state.remote_id,
        path: to_string(path),
        channel: topic.channel_name,
        values: values,
        ts: ts,
        seq: seq,
        source: :replay
      }
      Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{state.supervisor_id}:#{state.remote_id}", point_pub)

      channel_key = "#{path}/#{topic.channel_name}"
      next_ts = parse_iso8601(data["next_ts"])
      state =
        update_site(state, fn site ->
          site
          |> RSMP.Remote.Node.Site.clear_next_ts_before(channel_key, ts)
          |> RSMP.Remote.Node.Site.store_data_point(channel_key, seq, ts, values, next_ts)
        end)

      if get_in(state.site.channels, [channel_key]) == "stopped" do
        stopped_at = get_in(state.site.channel_stopped_at, [channel_key]) || DateTime.utc_now()
        update_site(state, fn site ->
          RSMP.Remote.Node.Site.stamp_next_ts_on_last(site, channel_key, stopped_at)
        end)
      else
        state
      end
    else
      Logger.warning("RSMP: #{state.supervisor_id}: Replay message missing 'values': #{inspect(data)}")
      state
    end
  end

  defp receive_replay_entry(state, _topic, _data), do: state

  # History handling

  defp receive_history(state, topic, data, properties) when is_map(data) do
    correlation_data = properties[:"Correlation-Data"]
    fetch_info = Map.get(state.pending_fetches, correlation_data)

    state =
      if fetch_info do
        entries = data["entries"] || []
        Enum.reduce(entries, state, fn entry, acc ->
          receive_history_entry(acc, topic, entry, fetch_info)
        end)
      else
        state
      end

    if data["complete"] && correlation_data && fetch_info do
      %{state | pending_fetches: Map.delete(state.pending_fetches, correlation_data)}
    else
      state
    end
  end

  defp receive_history(state, _topic, _data, _properties), do: state

  defp receive_history_entry(state, topic, entry, _fetch_info) do
    site = state.site
    path = topic.path
    ts = parse_iso8601(entry["ts"]) || DateTime.utc_now()
    seq = entry["seq"]
    values = RSMP.Remote.Node.Site.from_rsmp_status(site, path, entry["values"])

    Logger.debug("RSMP: #{state.supervisor_id}: Received history #{path}/#{topic.channel_name} seq=#{seq} values=#{inspect(values)}")

    point_pub = %{
      topic: "data_point",
      site: state.remote_id,
      path: to_string(path),
      channel: topic.channel_name,
      values: values,
      ts: ts,
      seq: seq,
      source: :history,
      complete: false
    }
    Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{state.supervisor_id}:#{state.remote_id}", point_pub)

    channel_key = "#{path}/#{topic.channel_name}"
    next_ts = parse_iso8601(entry["next_ts"])
    state =
      update_site(state, fn site ->
        site
        |> RSMP.Remote.Node.Site.clear_next_ts_before(channel_key, ts)
        |> RSMP.Remote.Node.Site.store_data_point(channel_key, seq, ts, values, next_ts)
      end)

    if get_in(state.site.channels, [channel_key]) == "stopped" do
      stopped_at = get_in(state.site.channel_stopped_at, [channel_key]) || DateTime.utc_now()
      update_site(state, fn site ->
        RSMP.Remote.Node.Site.stamp_next_ts_on_last(site, channel_key, stopped_at)
      end)
    else
      state
    end
  end

  # Fetch logic

  defp do_send_fetch(state, code, channel_name, from_ts, to_ts) do
    case RSMP.Registry.lookup_connection(state.supervisor_id) do
      [] ->
        state

      [{_pid, _}] ->
        correlation_id = SecureRandom.hex(8)
        channel_segment = if channel_name && channel_name != "", do: channel_name, else: "default"
        fetch_topic = "#{state.remote_id}/fetch/#{code}/#{channel_segment}"
        response_topic = "#{state.supervisor_id}/history/#{code}/#{channel_segment}"

        payload = %{}
        payload = if from_ts, do: Map.put(payload, "from", DateTime.to_iso8601(from_ts)), else: payload
        payload = if to_ts, do: Map.put(payload, "to", DateTime.to_iso8601(to_ts)), else: payload

        Logger.debug("RSMP: Sending fetch #{code}/#{channel_segment} to #{state.remote_id} from #{inspect(from_ts)} to #{inspect(to_ts)}")

        RSMP.Connection.publish_message(
          state.supervisor_id,
          fetch_topic,
          payload,
          %{retain: false, qos: 1},
          %{command_id: correlation_id, response_topic: response_topic}
        )

        pending_fetch = %{site_id: state.remote_id, code: code, channel_name: channel_name}
        %{state | pending_fetches: Map.put(state.pending_fetches, correlation_id, pending_fetch)}
    end
  end

  defp fetch_channel_gaps(state, code, channel_name, fallback_from_ts) do
    channel_key = "#{code}/#{channel_name}"
    channel_running = get_in(state.site.channels, [channel_key]) == "running"

    if not channel_running do
      state
    else
      now = DateTime.utc_now()
      site = state.site
      window_start = fallback_from_ts

      {time_ranges, sorted_points} =
        if site do
          seq_ranges = RSMP.Remote.Node.Site.gap_time_ranges(site, channel_key)
          sorted_points = RSMP.Remote.Node.Site.get_data_points(site, channel_key)
          next_ts_ranges = RSMP.Remote.Node.Site.next_ts_gap_ranges(sorted_points)

          ranges =
            (seq_ranges ++ next_ts_ranges)
            |> Enum.map(fn {from, to} -> {from, to || now} end)
            |> Enum.reject(fn {from, _to} -> is_nil(from) end)
            |> Enum.filter(fn {from, to} -> DateTime.compare(from, to) == :lt end)
            |> Enum.map(fn {from, to} ->
              clamped_from = if DateTime.compare(from, window_start) == :lt, do: window_start, else: from
              {clamped_from, to}
            end)
            |> Enum.filter(fn {from, to} -> DateTime.compare(from, to) == :lt end)
            |> merge_time_ranges()

          {ranges, sorted_points}
        else
          {[], []}
        end

      time_ranges =
        if time_ranges == [] do
          has_recent_data = Enum.any?(sorted_points, fn p ->
            DateTime.compare(p.ts, window_start) != :lt
          end)
          if has_recent_data, do: [], else: [{window_start, now}]
        else
          time_ranges
        end

      Enum.reduce(time_ranges, state, fn {from_ts, to_ts}, acc ->
        do_send_fetch(acc, code, channel_name, from_ts, to_ts)
      end)
    end
  end

  # Merge a list of {from, to} DateTime tuples: sort by from, then fold overlapping
  # or adjacent ranges into a single covering range.
  defp merge_time_ranges([]), do: []

  defp merge_time_ranges(ranges) do
    ranges
    |> Enum.sort_by(fn {from, _to} -> from end, DateTime)
    |> Enum.reduce([], fn {from, to}, acc ->
      case acc do
        [] ->
          [{from, to}]

        [{prev_from, prev_to} | rest] ->
          if DateTime.compare(from, prev_to) != :gt do
            latest_to = if DateTime.compare(to, prev_to) == :gt, do: to, else: prev_to
            [{prev_from, latest_to} | rest]
          else
            [{from, to}, {prev_from, prev_to} | rest]
          end
      end
    end)
    |> Enum.reverse()
  end

  # Helpers

  defp update_site(state, fun) do
    %{state | site: fun.(state.site)}
  end

  defp set_site_num_alarms(site) do
    num =
      site.alarms
      |> Enum.count(fn {_path, alarm} -> alarm["active"] end)

    %{site | num_alarms: num}
  end

  defp channel_state_key(path, channel_name) do
    normalized_channel =
      case channel_name do
        nil -> "default"
        "" -> "default"
        other -> to_string(other)
      end

    "#{to_string(path)}/#{normalized_channel}"
  end

  defp extract_status_envelope(data, retain) when is_map(data) do
    if Map.has_key?(data, "values") do
      type = if retain, do: "full", else: "delta"
      seq = data["seq"]
      ts = parse_iso8601(data["ts"])
      {type, seq, data["values"] || %{}, ts}
    else
      type = map_get_any(data, ["type", :type, "t", :t])
      seq = map_get_any(data, ["seq", :seq, "s", :s])
      inner_data = map_get_any(data, ["data", :data, "d", :d])

      cond do
        not is_nil(inner_data) and not is_nil(type) ->
          {type, seq, inner_data, nil}

        not is_nil(inner_data) ->
          {"full", seq, inner_data, nil}

        true ->
          {"full", seq, data, nil}
      end
    end
  end

  defp extract_status_envelope(data, _retain), do: {"full", nil, data, nil}

  defp map_get_any(map, keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp deep_merge_status(current_status, new_status)
       when is_map(current_status) and is_map(new_status) do
    Map.merge(current_status, new_status, fn _key, current_value, new_value ->
      if is_map(current_value) and is_map(new_value) do
        Map.merge(current_value, new_value)
      else
        new_value
      end
    end)
  end

  defp deep_merge_status(_current_status, new_status), do: new_status

  defp maybe_put_seq(status, nil), do: status

  defp maybe_put_seq(status, seq) when is_map(status) do
    Map.put(status, "seq", seq)
  end

  defp maybe_put_seq(status, seq) do
    %{"value" => status, "seq" => seq}
  end

  defp maybe_put_status_seq(status, current_status, nil, incoming_seq) do
    seq = incoming_seq || status_seq(current_status)
    maybe_put_seq(status, seq)
  end

  defp maybe_put_status_seq(status, current_status, channel_name, incoming_seq) do
    current_seq = status_seq(current_status)
    seq_map = if is_map(current_seq), do: current_seq, else: %{}
    seq_map = if incoming_seq, do: Map.put(seq_map, channel_name, incoming_seq), else: seq_map
    if seq_map == %{}, do: status, else: maybe_put_seq(status, seq_map)
  end

  defp status_seq(value) when is_map(value) do
    Map.get(value, "seq") || Map.get(value, :seq)
  end

  defp status_seq(_value), do: nil

  defp parse_iso8601(nil), do: nil

  defp parse_iso8601(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_iso8601(_), do: nil
end
