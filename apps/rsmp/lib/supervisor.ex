defmodule RSMP.Supervisor do
  use GenServer
  require Logger
  alias RSMP.{Utility, Topic, Path}

  # Must match MAX_POINTS in volume_chart_state.mjs
  @graph_window_seconds 60

  # Channels that support gap-fetch, derived at compile time from channel configs.
  # Tuple format: {code, channel_name}
  @gap_fetch_channels RSMP.Node.TLC.channel_configs()
    |> Enum.filter(fn config -> config.gap_fetch end)
    |> Enum.map(fn config -> {config.code, config.channel_name} end)

  defstruct(
    pid: nil,
    id: nil,
    sites: %{},
    connected: false,
    last_disconnected_at: nil,
    pending_fetches: %{}
  )

  def new(options \\ %{}), do: __struct__(options)

  # api

  def start_link(id) do
    GenServer.start_link(__MODULE__, id, name: RSMP.Registry.via_supervisor(id))
  end

  def site_ids(supervisor_id) do
    GenServer.call(RSMP.Registry.via_supervisor(supervisor_id), :site_ids)
  end

  def sites(supervisor_id) do
    GenServer.call(RSMP.Registry.via_supervisor(supervisor_id), :sites)
  end

  def site(supervisor_id, site_id) do
    GenServer.call(RSMP.Registry.via_supervisor(supervisor_id), {:site, site_id})
  end

  def set_plan(supervisor_id, site_id, plan) do
    GenServer.cast(RSMP.Registry.via_supervisor(supervisor_id), {:set_plan, site_id, plan})
  end

  def start_channel(supervisor_id, site_id, code, channel_name) do
    GenServer.cast(RSMP.Registry.via_supervisor(supervisor_id), {:throttle_channel, site_id, code, channel_name, "start"})
  end

  def stop_channel(supervisor_id, site_id, code, channel_name) do
    GenServer.cast(RSMP.Registry.via_supervisor(supervisor_id), {:throttle_channel, site_id, code, channel_name, "stop"})
  end

  def toggle_connection(supervisor_id) do
    GenServer.cast(RSMP.Registry.via_supervisor(supervisor_id), :toggle_connection)
  end

  def connected?(supervisor_id) do
    GenServer.call(RSMP.Registry.via_supervisor(supervisor_id), :connected?)
  end

  def send_fetch(supervisor_id, site_id, code, channel_name, from_ts, to_ts) do
    GenServer.cast(RSMP.Registry.via_supervisor(supervisor_id), {:send_fetch, site_id, code, channel_name, from_ts, to_ts})
  end

  def data_points(supervisor_id, site_id, channel_key) do
    GenServer.call(RSMP.Registry.via_supervisor(supervisor_id), {:data_points, site_id, channel_key})
  end

  def data_points_with_keys(supervisor_id, site_id, channel_key) do
    GenServer.call(RSMP.Registry.via_supervisor(supervisor_id), {:data_points_with_keys, site_id, channel_key})
  end

  def has_seq_gaps?(supervisor_id, site_id, channel_key) do
    GenServer.call(RSMP.Registry.via_supervisor(supervisor_id), {:has_seq_gaps?, site_id, channel_key})
  end

  def seq_gaps(supervisor_id, site_id, channel_key) do
    GenServer.call(RSMP.Registry.via_supervisor(supervisor_id), {:seq_gaps, site_id, channel_key})
  end

  def gap_time_ranges(supervisor_id, site_id, channel_key) do
    GenServer.call(RSMP.Registry.via_supervisor(supervisor_id), {:gap_time_ranges, site_id, channel_key})
  end



  # Callbacks

  @impl true
  def init(id) do
    Logger.info("RSMP: Supervisor #{id} GenServer init")
    Process.flag(:trap_exit, true)

    if Application.get_env(:rsmp, :emqtt_connect, true) do
      emqtt_opts = Application.get_env(:rsmp, :emqtt)
      emqtt_opts = emqtt_opts |> Keyword.put(:clientid, id)

      Logger.info("RSMP: Starting emqtt with options: #{inspect(emqtt_opts)}")
      {:ok, pid} = :emqtt.start_link(emqtt_opts)
      supervisor = new(pid: pid, id: id)
      send(self(), :connect)
      {:ok, supervisor}
    else
      {:ok, new(id: id)}
    end
  end

  @impl true
  def terminate(:shutdown, _state), do: :ok
  def terminate(:normal, _state), do: :ok

  def terminate(reason, _state) do
    Logger.error("RSMP: Supervisor GenServer terminating: #{inspect(reason)}")
  end

  def subscribe_to_topics(%{pid: pid, id: id}) do
    levels = Application.get_env(:rsmp, :topic_prefix_levels, 3)
    wildcard_id = List.duplicate("+", levels) |> Enum.join("/")

    # Subscribe to statuses
    {:ok, _, _} = :emqtt.subscribe(pid, {"#{wildcard_id}/status/#", 2})

    # Subscribe to online/offline state
    {:ok, _, _} = :emqtt.subscribe(pid, {"#{wildcard_id}/presence/#", 2})

    # Subscribe to alarms
    {:ok, _, _} = :emqtt.subscribe(pid, {"#{wildcard_id}/alarm/#", 2})

    # Subscribe to channel states (channel lifecycle)
    {:ok, _, _} = :emqtt.subscribe(pid, {"#{wildcard_id}/channel/#", 2})

    # Subscribe to replay (buffered data from sites reconnecting)
    {:ok, _, _} = :emqtt.subscribe(pid, {"#{wildcard_id}/replay/#", 2})

    # Subscribe to our response topics
    {:ok, _, _} = :emqtt.subscribe(pid, {"#{wildcard_id}/result/#", 2})

    # Subscribe to history responses (fetch results directed to us)
    {:ok, _, _} = :emqtt.subscribe(pid, {"#{id}/history/#", 2})
  end

  @impl true
  def handle_call(:site_ids, _from, supervisor) do
    {:reply, Map.keys(supervisor.sites), supervisor}
  end

  @impl true
  def handle_call(:sites, _from, supervisor) do
    {:reply, supervisor.sites, supervisor}
  end

  @impl true
  def handle_call({:site, id}, _from, supervisor) do
    {:reply, supervisor.sites[id], supervisor}
  end

  @impl true
  def handle_call({:data_points, site_id, channel_key}, _from, supervisor) do
    points =
      case supervisor.sites[site_id] do
        nil -> []
        site -> RSMP.Remote.Node.Site.get_data_points(site, channel_key)
      end
    {:reply, points, supervisor}
  end

  @impl true
  def handle_call({:data_points_with_keys, site_id, channel_key}, _from, supervisor) do
    points =
      case supervisor.sites[site_id] do
        nil -> []
        site -> RSMP.Remote.Node.Site.get_data_points_with_keys(site, channel_key)
      end
    {:reply, points, supervisor}
  end

  @impl true
  def handle_call({:has_seq_gaps?, site_id, channel_key}, _from, supervisor) do
    result =
      case supervisor.sites[site_id] do
        nil -> false
        site -> RSMP.Remote.Node.Site.has_seq_gaps?(site, channel_key)
      end
    {:reply, result, supervisor}
  end

  @impl true
  def handle_call({:seq_gaps, site_id, channel_key}, _from, supervisor) do
    result =
      case supervisor.sites[site_id] do
        nil -> []
        site -> RSMP.Remote.Node.Site.seq_gaps(site, channel_key)
      end
    {:reply, result, supervisor}
  end

  @impl true
  def handle_call({:gap_time_ranges, site_id, channel_key}, _from, supervisor) do
    result =
      case supervisor.sites[site_id] do
        nil -> []
        site -> RSMP.Remote.Node.Site.gap_time_ranges(site, channel_key)
      end
    {:reply, result, supervisor}
  end

  @impl true
  def handle_call(:connected?, _from, supervisor) do
    {:reply, supervisor.connected, supervisor}
  end

  @impl true
  def handle_cast({:set_plan, site_id, plan}, supervisor) do
    # Send command to device
    # set current time plan
    path = "tlc.plan.set"
    topic = RSMP.Topic.new(site_id, "command", "tlc.plan.set")
    command_id = SecureRandom.hex(2)

    Logger.info(
      "RSMP: Sending '#{path}' command #{command_id} to #{site_id}: Please switch to plan #{plan}"
    )

    properties = %{
      "Response-Topic": "#{site_id}/result/tlc.plan.set",
      "Correlation-Data": command_id
    }

    # Logger.info("response/#{site_id}/#{topic}")

    :ok =
      :emqtt.publish_async(
        supervisor.pid,
        to_string(topic),
        properties,
        Utility.to_payload(%{"plan" => plan}),
        [retain: true, qos: 1],
        :infinity,
        {&publish_done/1, []}
      )

    {:noreply, supervisor}
  end

  @impl true
  def handle_cast(:toggle_connection, %{connected: true} = supervisor) do
    pid = supervisor.pid
    now = DateTime.utc_now()
    supervisor = %{supervisor | pid: nil, connected: false, last_disconnected_at: now}
    if pid, do: :emqtt.disconnect(pid)

    # Stamp next_ts on last data point for all known sites — no data will arrive while disconnected
    supervisor =
      Enum.reduce(supervisor.sites, supervisor, fn {id, _site}, sup ->
        update_in(sup.sites[id], fn site ->
          Enum.reduce(@gap_fetch_channels, site, fn {code, channel_name}, acc ->
            RSMP.Remote.Node.Site.stamp_next_ts_on_last(acc, "#{code}/#{channel_name}", now)
          end)
        end)
      end)

    Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{supervisor.id}", %{topic: "connected", connected: false})
    {:noreply, supervisor}
  end

  @impl true
  def handle_cast(:toggle_connection, %{connected: false} = supervisor) do
    send(self(), :restart_mqtt)
    {:noreply, supervisor}
  end

  @impl true
  def handle_cast({:send_fetch, site_id, code, channel_name, from_ts, to_ts}, supervisor) do
    supervisor = do_send_fetch(supervisor, site_id, code, channel_name, from_ts, to_ts)
    {:noreply, supervisor}
  end

  @impl true
  def handle_cast({:throttle_channel, site_id, code, channel_name, action}, supervisor) do
    channel_segment =
      case channel_name do
        nil -> "default"
        "" -> "default"
        value -> to_string(value)
      end

    topic = Topic.new(site_id, "throttle", code, [channel_segment])

    Logger.info(
      "RSMP: Sending throttle #{action} for #{code}/#{channel_segment} to #{site_id}"
    )

    :emqtt.publish_async(
      supervisor.pid,
      to_string(topic),
      Utility.to_payload(%{"action" => action}),
      [retain: false, qos: 1],
      &publish_done/1
    )

    {:noreply, supervisor}
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, %{pid: pid} = state) do
    Logger.warning("RSMP: Supervisor MQTT connection process exited: #{inspect(reason)}. Restarting in 5s...")
    Process.send_after(self(), :restart_mqtt, 5_000)
    {:noreply, %{state | pid: nil}}
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info(:restart_mqtt, state) do
    emqtt_opts = Application.get_env(:rsmp, :emqtt)
    emqtt_opts = emqtt_opts |> Keyword.put(:clientid, state.id)

    Logger.info("RSMP: Restarting emqtt with options: #{inspect(emqtt_opts)}")
    {:ok, pid} = :emqtt.start_link(emqtt_opts)
    send(self(), :connect)
    {:noreply, %{state | pid: pid}}
  end

  @impl true
  def handle_info(:connect, %{pid: nil} = state) do
    {:noreply, state}
  end

  def handle_info(:connect, state) do
    case :emqtt.connect(state.pid) do
      {:ok, _} ->
        Logger.info("RSMP: Supervisor connected to MQTT broker")
        subscribe_to_topics(state)
        state = %{state | connected: true}
        state = clear_gaps_and_fetch_all_sites(state)
        Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{state.id}", %{topic: "connected", connected: true})
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("RSMP: Supervisor failed to connect to MQTT broker: #{inspect(reason)}. Retrying in 5s...")
        Process.send_after(self(), :connect, 5_000)
        {:noreply, state}
    end
  end

  # mqtt
  @impl true
  def handle_info({:connected, _publish}, supervisor) do
    Logger.info("RSMP: Connected")
    subscribe_to_topics(supervisor)
    supervisor = %{supervisor | connected: true}
    supervisor = clear_gaps_and_fetch_all_sites(supervisor)
    Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{supervisor.id}", %{topic: "connected", connected: true})
    {:noreply, supervisor}
  end

  @impl true
  def handle_info({:disconnected, _publish}, supervisor) do
    Logger.info("RSMP: Disconnected")
    now = DateTime.utc_now()
    supervisor = %{supervisor | connected: false, last_disconnected_at: now}

    # Stamp next_ts on last data point for all known sites — no data will arrive while disconnected
    supervisor =
      Enum.reduce(supervisor.sites, supervisor, fn {id, _site}, sup ->
        update_in(sup.sites[id], fn site ->
          Enum.reduce(@gap_fetch_channels, site, fn {code, channel_name}, acc ->
            RSMP.Remote.Node.Site.stamp_next_ts_on_last(acc, "#{code}/#{channel_name}", now)
          end)
        end)
      end)

    Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{supervisor.id}", %{topic: "connected", connected: false})
    {:noreply, supervisor}
  end

  @impl true
  def handle_info({:publish, publish}, supervisor) do
    topic = Topic.from_string(publish.topic)
    data = Utility.from_payload(publish[:payload])
    properties = publish[:properties]

    supervisor =
      case topic.type do
        "presence" ->
          receive_presence(supervisor, topic.id, data)

        "status" ->
          if data == nil do
            # Channel cleared (empty retained message)
            supervisor
          else
            retain = publish[:retain] == true or publish[:retain] == 1

            if is_map(data) and Map.has_key?(data, "entries") do
              # Batched status message: process each entry individually.
              # Retain applies only to the final entry (per spec).
              entries = data["entries"] || []
              last_idx = length(entries) - 1

              entries
              |> Enum.with_index()
              |> Enum.reduce(supervisor, fn {entry, idx}, acc ->
                entry_retain = retain and idx == last_idx
                receive_status(acc, topic, entry, entry_retain)
              end)
            else
              receive_status(supervisor, topic, data, retain)
            end
          end

        "result" ->
          command_id = properties[:"Correlation-Data"]
          receive_result(supervisor, topic, data, command_id)

        "channel" ->
          receive_channel(supervisor, topic, data)

        "replay" ->
          receive_replay(supervisor, topic, data)

        "history" ->
          receive_history(supervisor, topic, data, properties)

        "alarm" ->
          receive_alarm(supervisor, topic, data)

        _ ->
          receive_unknown(supervisor, topic, publish)
      end

    {:noreply, supervisor}
  end

  # helpers
  defp receive_presence(supervisor, id, data) when data in ["online", "offline", "shutdown"] do
    {supervisor, site} = get_site(supervisor, id)
    previous_presence = site.presence
    site = %{site | presence: data}
    supervisor = put_in(supervisor.sites[id], site)
    Logger.info("RSMP: Supervisor received presence from #{id}: #{data}")

    pub = %{topic: "presence", site: id, presence: data}
    Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{supervisor.id}", pub)
    Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{supervisor.id}:#{id}", pub)

    # When a site goes offline, stamp next_ts on last data point for channels with charts
    supervisor =
      if data in ["offline", "shutdown"] && previous_presence == "online" do
        now = DateTime.utc_now()
        update_in(supervisor.sites[id], fn site ->
          Enum.reduce(@gap_fetch_channels, site, fn {code, channel_name}, acc ->
            RSMP.Remote.Node.Site.stamp_next_ts_on_last(acc, "#{code}/#{channel_name}", now)
          end)
        end)
      else
        supervisor
      end

    # When a site comes online, fetch any missing data
    supervisor =
      if data == "online" && previous_presence != "online" do
        from_ts =
          supervisor.last_disconnected_at ||
            DateTime.add(DateTime.utc_now(), -@graph_window_seconds, :second)

        Enum.reduce(@gap_fetch_channels, supervisor, fn {code, channel_name}, acc ->
          fetch_channel_gaps(acc, id, code, channel_name, from_ts)
        end)
      else
        supervisor
      end

    supervisor
  end

  defp receive_presence(supervisor, id, data) do
    Logger.warning("RSMP: Supervisor received unknown presence from #{id}: #{inspect(data)}")
    supervisor
  end

  defp receive_result(supervisor, topic, result, command_id) do
    Logger.info("RSMP: #{topic.id}: Received result: #{topic.path}: #{inspect(result)}")

    pub = %{
      topic: "response",
      response: %{
        id: topic.id,
        command: topic.path.code,
        command_id: command_id,
        result: result
      }
    }

    Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{supervisor.id}", pub)
    Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{supervisor.id}:#{topic.id}", pub)

    supervisor
  end

  defp receive_status(supervisor, topic, data, retain) do
    id = topic.id
    path = topic.path
    {supervisor, site} = get_site(supervisor, id)

    # New format: {"values": {...}, "seq": N}, retain flag determines full vs delta.
    # Legacy format: {"type": "full|delta", "seq": N, "data": {...}} also supported.
    {status_type, seq, values, event_ts} = extract_status_envelope(data, retain)

    # Use code (without channel name) as the status key
    status_key = to_string(path)

    new_status = from_rsmp_status(site, path, values)

    current_status = get_in(site.statuses, [status_key]) || %{}

    status =
      if status_type == "delta" do
        deep_merge_status(current_status, new_status)
      else
        new_status
      end

    status = maybe_put_status_seq(status, current_status, topic.channel_name, seq)

    supervisor = put_in(supervisor.sites[id].statuses[status_key], status)

    case status_type do
      "delta" ->
        Logger.info(
          "RSMP: #{id}: Received delta #{status_key}: #{inspect(new_status)} from #{id}"
        )

      _ ->
        Logger.info("RSMP: #{id}: Received status #{status_key}: #{inspect(status)} from #{id}")
    end

    pub = %{topic: "status", site: id, status: %{topic.path => status}}
    Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{supervisor.id}", pub)
    Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{supervisor.id}:#{id}", pub)

    channel_key = channel_state_key(path, topic.channel_name)
    channel_pub = %{topic: "channel_data", site: id, channel: channel_key}
    Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{supervisor.id}:#{id}", channel_pub)

    # Only create data points for non-retained (live/delta) messages.
    # Retained messages are state snapshots delivered on subscribe — they update
    # the status display but should not appear as historical graph entries,
    # because they may carry timestamps from before the supervisor started.
    # The fetch/history path provides the graph baseline (including the initial
    # full published by channel start).
    supervisor =
      if retain do
        supervisor
      else
        point_ts = event_ts || DateTime.utc_now()
        point_pub = %{
          topic: "data_point",
          site: id,
          path: status_key,
          channel: topic.channel_name,
          values: new_status,
          ts: point_ts,
          seq: seq,
          source: :live
        }
        Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{supervisor.id}:#{id}", point_pub)

        # Persist this data point so the LiveView can build history on mount/reconnect.
        # clear_next_ts_before removes the next_ts marker on the previous point when
        # its successor arrives, so trailing gaps close when live data resumes.
        channel_key = "#{status_key}/#{topic.channel_name}"
        update_in(supervisor.sites[id], fn site ->
          site
          |> RSMP.Remote.Node.Site.clear_next_ts_before(channel_key, point_ts)
          |> RSMP.Remote.Node.Site.store_data_point(channel_key, seq, point_ts, new_status)
        end)
      end

    supervisor
  end

  defp receive_alarm(supervisor, topic, data) do
    alarm = %{
      "active" => data["aSt"] == "Active"
    }

    id = topic.id
    path_string = to_string(topic.path)
    {supervisor, site} = get_site(supervisor, id)
    alarms = site.alarms |> Map.put(path_string, alarm)
    site = %{site | alarms: alarms} |> set_site_num_alarms()
    supervisor = put_in(supervisor.sites[id], site)

    Logger.info("RSMP: #{topic.id}: Received alarm #{path_string}: #{inspect(alarm)}")
    pub = %{topic: "alarm", alarm: %{topic.path => alarm}}
    Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{supervisor.id}", pub)
    Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{supervisor.id}:#{id}", pub)

    supervisor
  end

  defp receive_channel(supervisor, topic, data) when is_map(data) do
    channel_name =
      case topic.channel_name do
        name when is_binary(name) and name != "" -> name
        _ -> nil
      end

    state = data["state"] || data[:state]

    cond do
      is_nil(channel_name) ->
        Logger.warning("RSMP: #{topic.id}: Ignoring channel state without channel name: #{inspect(topic)}")
        supervisor

      state not in ["running", "stopped"] ->
        Logger.warning("RSMP: #{topic.id}: Ignoring invalid channel state payload: #{inspect(data)}")
        supervisor

      true ->
        id = topic.id
        {supervisor, site} = get_site(supervisor, id)
        path = Path.new(topic.path.code, [])
        channel_key = channel_state_key(path, channel_name)
        previous_state = get_in(site.channels, [channel_key])

        # Record the timestamp when a channel is stopped, and stamp next_ts on last data point
        supervisor =
          if state == "stopped" do
            now = DateTime.utc_now()
            supervisor = put_in(supervisor.sites[id].channel_stopped_at[channel_key], now)
            update_in(supervisor.sites[id], fn site ->
              RSMP.Remote.Node.Site.stamp_next_ts_on_last(site, channel_key, now)
            end)
          else
            supervisor
          end

        supervisor = put_in(supervisor.sites[id].channels[channel_key], state)

        Logger.info("RSMP: #{id}: Received channel state #{channel_key}: #{state}")

        pub = %{topic: "channel", site: id, channel: channel_key, state: state}
        Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{supervisor.id}", pub)
        Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{supervisor.id}:#{id}", pub)

        # When a channel starts (from stopped or first seen), fetch missed data.
        # Use graph-window fallback (now - 60s) so the fetch covers the visible
        # time range without pulling in entries from before the app started.
        supervisor =
          if state == "running" && previous_state in ["stopped", nil] do
            fallback_ts = DateTime.add(DateTime.utc_now(), -@graph_window_seconds, :second)

            case Enum.find(@gap_fetch_channels, fn {code, channel_name} ->
              "#{code}/#{channel_name}" == channel_key
            end) do
              {code, channel_name} -> fetch_channel_gaps(supervisor, id, code, channel_name, fallback_ts)
              nil -> supervisor
            end
          else
            supervisor
          end

        supervisor
    end
  end

  defp receive_channel(supervisor, topic, data) do
    Logger.warning("RSMP: #{topic.id}: Ignoring channel state payload: #{inspect(data)}")
    supervisor
  end

  defp receive_replay(supervisor, topic, data) when is_map(data) do
    # Handle batched replay messages with entries array
    if Map.has_key?(data, "entries") do
      entries = data["entries"] || []
      complete = data["complete"]
      truncated = data["truncated"]

      supervisor =
        Enum.reduce(entries, supervisor, fn entry, acc ->
          entry_data = Map.merge(entry, %{"complete" => false})
          receive_replay_entry(acc, topic, entry_data)
        end)

      # Broadcast complete/truncated status from the wrapper
      if complete do
        site_id = topic.id
        complete_pub = %{
          topic: "data_point",
          site: site_id,
          path: to_string(topic.path),
          channel: topic.channel_name,
          source: :replay,
          complete: true,
          truncated: truncated
        }
        Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{supervisor.id}:#{site_id}", complete_pub)
      end

      supervisor
    else
      receive_replay_entry(supervisor, topic, data)
    end
  end

  defp receive_replay(supervisor, _topic, _data), do: supervisor

  defp receive_replay_entry(supervisor, topic, data) when is_map(data) do
    site_id = topic.id
    path = topic.path

    if data["values"] do
      {supervisor, site} = get_site(supervisor, site_id)
      ts = parse_iso8601(data["ts"]) || DateTime.utc_now()
      seq = data["seq"]
      values = from_rsmp_status(site, path, data["values"])

      Logger.info("RSMP: #{supervisor.id}: Received replay #{path}/#{topic.channel_name} seq=#{seq} values=#{inspect(values)}")

      point_pub = %{
        topic: "data_point",
        site: site_id,
        path: to_string(path),
        channel: topic.channel_name,
        values: values,
        ts: ts,
        seq: seq,
        source: :replay,
        complete: data["complete"]
      }
      Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{supervisor.id}:#{site_id}", point_pub)

      # Persist so the LiveView can read history on mount/reconnect
      channel_key = "#{path}/#{topic.channel_name}"
      next_ts = parse_iso8601(data["next_ts"])
      supervisor =
        update_in(supervisor.sites[site_id], fn site ->
          site
          |> RSMP.Remote.Node.Site.clear_next_ts_before(channel_key, ts)
          |> RSMP.Remote.Node.Site.store_data_point(channel_key, seq, ts, values, next_ts)
        end)

      # If the channel is currently stopped, re-stamp next_ts on the last data point
      # so the chart shows grey instead of extending the last color to now
      supervisor =
        if get_in(supervisor.sites[site_id].channels, [channel_key]) == "stopped" do
          stopped_at = get_in(supervisor.sites[site_id].channel_stopped_at, [channel_key]) || DateTime.utc_now()
          update_in(supervisor.sites[site_id], fn site ->
            RSMP.Remote.Node.Site.stamp_next_ts_on_last(site, channel_key, stopped_at)
          end)
        else
          supervisor
        end

      supervisor
    else
      Logger.warning("RSMP: #{supervisor.id}: Replay message missing 'values': #{inspect(data)}")
      supervisor
    end
  end

  defp receive_replay_entry(supervisor, _topic, _data), do: supervisor

  defp receive_history(supervisor, topic, data, properties) when is_map(data) do
    correlation_data = properties[:"Correlation-Data"]
    fetch_info = Map.get(supervisor.pending_fetches, correlation_data)

    supervisor =
      if fetch_info do
        # Handle batched history messages with entries array
        if Map.has_key?(data, "entries") do
          entries = data["entries"] || []
          Enum.reduce(entries, supervisor, fn entry, acc ->
            receive_history_entry(acc, topic, entry, fetch_info)
          end)
        else
          if data["values"] do
            receive_history_entry(supervisor, topic, data, fetch_info)
          else
            supervisor
          end
        end
      else
        supervisor
      end

    # Release pending fetch when complete
    if data["complete"] && correlation_data && fetch_info do
      pending = Map.delete(supervisor.pending_fetches, correlation_data)
      %{supervisor | pending_fetches: pending}
    else
      supervisor
    end
  end

  defp receive_history(supervisor, _topic, _data, _properties), do: supervisor

  defp receive_history_entry(supervisor, topic, entry, fetch_info) do
    site_id = fetch_info.site_id
    path = topic.path
    {supervisor, site} = get_site(supervisor, site_id)
    ts = parse_iso8601(entry["ts"]) || DateTime.utc_now()
    seq = entry["seq"]
    values = from_rsmp_status(site, path, entry["values"])

    Logger.info("RSMP: #{supervisor.id}: Received history #{path}/#{topic.channel_name} seq=#{seq} values=#{inspect(values)}")

    point_pub = %{
      topic: "data_point",
      site: site_id,
      path: to_string(path),
      channel: topic.channel_name,
      values: values,
      ts: ts,
      seq: seq,
      source: :history,
      complete: false
    }
    Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{supervisor.id}:#{site_id}", point_pub)

    # Persist data point so the LiveView can build history on mount/reconnect
    channel_key = "#{path}/#{topic.channel_name}"
    next_ts = parse_iso8601(entry["next_ts"])
    supervisor =
      update_in(supervisor.sites[site_id], fn site ->
        site
        |> RSMP.Remote.Node.Site.clear_next_ts_before(channel_key, ts)
        |> RSMP.Remote.Node.Site.store_data_point(channel_key, seq, ts, values, next_ts)
      end)

    # If the channel is currently stopped, re-stamp next_ts on the last data point
    # so the chart shows grey instead of extending the last color to now
    if get_in(supervisor.sites[site_id].channels, [channel_key]) == "stopped" do
      stopped_at = get_in(supervisor.sites[site_id].channel_stopped_at, [channel_key]) || DateTime.utc_now()
      update_in(supervisor.sites[site_id], fn site ->
        RSMP.Remote.Node.Site.stamp_next_ts_on_last(site, channel_key, stopped_at)
      end)
    else
      supervisor
    end
  end

  # catch-all in case old retained messages are received from the broker
  defp receive_unknown(supervisor, topic, publish) do
    Logger.warning("Unhandled publish, topic: #{inspect(topic)}, publish: #{inspect(publish)}")
    supervisor
  end

  def publish_done(data) do
    Logger.debug("RSMP: Publish result: #{Kernel.inspect(data)}")
  end

  def set_site_num_alarms(site) do
    num =
      site.alarms
      |> Enum.count(fn {_path, alarm} ->
        alarm["active"]
      end)

    site |> Map.put(:num_alarms, num)
  end

  defp get_site(supervisor, id) do
    supervisor =
      if supervisor.sites[id],
        do: supervisor,
        else: put_in(supervisor.sites[id], RSMP.Remote.Node.Site.new(id: id))

    {supervisor, supervisor.sites[id]}
  end

  def module(supervisor, code), do: supervisor.modules |> Map.fetch!(code)
  def commander(supervisor, code), do: module(supervisor, code).commander()
  def converter(supervisor, code), do: module(supervisor, code).converter()

  def from_rsmp_status(supervisor, path, data) do
    converter(supervisor, path.code).from_rsmp_status(path.code, data)
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

  defp extract_status_envelope(data, retain) when is_map(data) do
    # New format: {"values": {...}, "seq": N, "ts": "..."} — full vs delta determined by retain flag
    if Map.has_key?(data, "values") do
      type = if retain, do: "full", else: "delta"
      seq = data["seq"]
      ts = parse_iso8601(data["ts"])
      {type, seq, data["values"] || %{}, ts}
    else
      # Legacy format: {"type": "full|delta", "seq": N, "data": {...}}
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
    Enum.find_value(keys, fn key ->
      Map.get(map, key)
    end)
  end

  defp status_seq(value) when is_map(value) do
    Map.get(value, "seq") || Map.get(value, :seq)
  end

  defp status_seq(_value), do: nil


  defp channel_state_key(path, channel_name) do
    normalized_channel =
      case channel_name do
        nil -> "default"
        "" -> "default"
        other -> to_string(other)
      end

    "#{to_string(path)}/#{normalized_channel}"
  end

  defp do_send_fetch(supervisor, site_id, code, channel_name, from_ts, to_ts) do
    if supervisor.pid == nil do
      supervisor
    else
      correlation_id = SecureRandom.hex(8)
      channel_segment = if channel_name && channel_name != "", do: channel_name, else: "default"
      response_topic = "#{supervisor.id}/history/#{code}/#{channel_segment}"
      fetch_topic = "#{site_id}/fetch/#{code}/#{channel_segment}"

      payload = %{}
      payload = if from_ts, do: Map.put(payload, "from", DateTime.to_iso8601(from_ts)), else: payload
      payload = if to_ts, do: Map.put(payload, "to", DateTime.to_iso8601(to_ts)), else: payload

      Logger.info("RSMP: Sending fetch #{code}/#{channel_segment} to #{site_id} from #{inspect(from_ts)} to #{inspect(to_ts)}")

      properties = %{
        "Response-Topic": response_topic,
        "Correlation-Data": correlation_id
      }

      :emqtt.publish_async(
        supervisor.pid,
        fetch_topic,
        properties,
        Utility.to_payload(payload),
        [retain: false, qos: 1],
        :infinity,
        {&publish_done/1, []}
      )

      pending_fetch = %{site_id: site_id, code: code, channel_name: channel_name}
      pending_fetches = Map.put(supervisor.pending_fetches, correlation_id, pending_fetch)
      %{supervisor | pending_fetches: pending_fetches}
    end
  end

  # Called when the supervisor reconnects to MQTT. Fetches missed data for all
  # known sites. Gap markers are progressively consumed as replay data fills in.
  defp clear_gaps_and_fetch_all_sites(supervisor) do
    from_ts =
      supervisor.last_disconnected_at ||
        DateTime.add(DateTime.utc_now(), -@graph_window_seconds, :second)

    Enum.reduce(supervisor.sites, supervisor, fn {id, _site}, sup ->
      Enum.reduce(@gap_fetch_channels, sup, fn {code, channel_name}, acc ->
        fetch_channel_gaps(acc, id, code, channel_name, from_ts)
      end)
    end)
  end

  # Fetch missing data for a channel. Uses seq-based gap detection as the primary
  # mechanism. Falls back to fallback_from_ts → now when no seq gaps have been
  # detected yet (e.g. right after reconnect or channel restart, before new data
  # has arrived past the gap).
  defp fetch_channel_gaps(supervisor, site_id, code, channel_name, fallback_from_ts) do
    channel_key = "#{code}/#{channel_name}"
    now = DateTime.utc_now()

    time_ranges =
      case supervisor.sites[site_id] do
        nil ->
          []

        site ->
          seq_ranges = RSMP.Remote.Node.Site.gap_time_ranges(site, channel_key)

          sorted_points =
            RSMP.Remote.Node.Site.get_data_points(site, channel_key)

          next_ts_ranges = RSMP.Remote.Node.Site.next_ts_gap_ranges(sorted_points)

          (seq_ranges ++ next_ts_ranges)
          |> Enum.map(fn {from, to} -> {from, to || now} end)
          |> Enum.reject(fn {from, _to} -> is_nil(from) end)
          |> Enum.filter(fn {from, to} -> DateTime.compare(from, to) == :lt end)
      end

    time_ranges =
      if time_ranges == [] do
        [{fallback_from_ts, now}]
      else
        time_ranges
      end

    Enum.reduce(time_ranges, supervisor, fn {from_ts, to_ts}, sup ->
      do_send_fetch(sup, site_id, code, channel_name, from_ts, to_ts)
    end)
  end

  defp parse_iso8601(nil), do: nil

  defp parse_iso8601(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_iso8601(_), do: nil
end
