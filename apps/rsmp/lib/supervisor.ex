defmodule RSMP.Supervisor do
  use GenServer
  require Logger
  alias RSMP.{Utility, Topic, Path}

  defstruct(
    pid: nil,
    id: nil,
    sites: %{}
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

  def start_stream(supervisor_id, site_id, module, code, stream_name) do
    GenServer.cast(RSMP.Registry.via_supervisor(supervisor_id), {:throttle_stream, site_id, module, code, stream_name, "start"})
  end

  def stop_stream(supervisor_id, site_id, module, code, stream_name) do
    GenServer.cast(RSMP.Registry.via_supervisor(supervisor_id), {:throttle_stream, site_id, module, code, stream_name, "stop"})
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

  def subscribe_to_topics(%{pid: pid, id: _id}) do
    levels = Application.get_env(:rsmp, :topic_prefix_levels, 3)
    wildcard_id = List.duplicate("+", levels) |> Enum.join("/")

    # Subscribe to statuses
    {:ok, _, _} = :emqtt.subscribe(pid, {"#{wildcard_id}/status/#", 2})

    # Subscribe to online/offline state
    {:ok, _, _} = :emqtt.subscribe(pid, {"#{wildcard_id}/presence/#", 2})

    # Subscribe to alarms
    {:ok, _, _} = :emqtt.subscribe(pid, {"#{wildcard_id}/alarm/#", 2})

    # Subscribe to stream states
    {:ok, _, _} = :emqtt.subscribe(pid, {"#{wildcard_id}/stream/#", 2})

    # Subscribe to our response topics
    {:ok, _, _} = :emqtt.subscribe(pid, {"#{wildcard_id}/result/#", 2})
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
  def handle_cast({:set_plan, site_id, plan}, supervisor) do
    # Send command to device
    # set current time plan
    path = "tlc.plan.set"
    topic = RSMP.Topic.new(site_id, "command", "tlc", "plan.set")
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
  def handle_cast({:throttle_stream, site_id, module, code, stream_name, action}, supervisor) do
    stream_segment =
      case stream_name do
        nil -> "default"
        "" -> "default"
        value -> to_string(value)
      end

    topic = Topic.new(site_id, "throttle", module, code, [stream_segment])

    Logger.info(
      "RSMP: Sending throttle #{action} for #{module}.#{code}/#{stream_segment} to #{site_id}"
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
    {:noreply, supervisor}
  end

  @impl true
  def handle_info({:disconnected, _publish}, supervisor) do
    Logger.info("RSMP: Disconnected")
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
            # Stream cleared (empty retained message)
            supervisor
          else
            receive_status(supervisor, topic, data)
          end

        "result" ->
          command_id = properties[:"Correlation-Data"]
          receive_result(supervisor, topic, data, command_id)

        "stream" ->
          receive_stream(supervisor, topic, data)

        "alarm" ->
          receive_alarm(supervisor, topic, data)

        _ ->
          receive_unknown(supervisor, topic, publish)
      end

    {:noreply, supervisor}
  end

  # helpers
  defp receive_presence(supervisor, id, data) do
    {supervisor, site} = get_site(supervisor, id)
    online = data == "online"
    site = %{site | online: online}
    supervisor = put_in(supervisor.sites[id], site)
    Logger.info("RSMP: Supervisor received presence from #{id}: #{data}")

    pub = %{topic: "presence", site: id, online: online}
    Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{supervisor.id}", pub)
    Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{supervisor.id}:#{id}", pub)

    supervisor
  end

  defp receive_result(supervisor, topic, result, command_id) do
    Logger.info("RSMP: #{topic.id}: Received result: #{topic.path}: #{inspect(result)}")

    pub = %{
      topic: "response",
      response: %{
        id: topic.id,
        module: topic.path.module,
        command: topic.path.code,
        command_id: command_id,
        result: result
      }
    }

    Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{supervisor.id}", pub)
    Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{supervisor.id}:#{topic.id}", pub)

    supervisor
  end

  defp receive_status(supervisor, topic, data) do
    id = topic.id
    path = topic.path
    {supervisor, site} = get_site(supervisor, id)

    # Status may arrive as stream envelope (%{"type","seq","data"}), compact envelope
    # (%{"t","s","d"}), atom-keyed variants, or plain status payload.
    {status_type, seq, data} = extract_status_envelope(data)

    # Use code (without stream name) as the status key
    status_key = to_string(path)

    new_status = from_rsmp_status(site, path, data)

    current_status = get_in(site.statuses, [status_key]) || %{}

    status =
      if status_type == "delta" do
        deep_merge_status(current_status, new_status)
      else
        new_status
      end

    status = maybe_put_status_seq(status, current_status, topic.stream_name, seq)

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

  defp receive_stream(supervisor, topic, data) when is_map(data) do
    stream_name =
      case topic.path.component do
        [name | _] when is_binary(name) and name != "" -> name
        _ -> nil
      end

    state = data["state"] || data[:state]

    cond do
      is_nil(stream_name) ->
        Logger.warning("RSMP: #{topic.id}: Ignoring stream state without stream name: #{inspect(topic)}")
        supervisor

      state not in ["running", "stopped"] ->
        Logger.warning("RSMP: #{topic.id}: Ignoring invalid stream state payload: #{inspect(data)}")
        supervisor

      true ->
        id = topic.id
        {supervisor, _site} = get_site(supervisor, id)
        path = Path.new(topic.path.module, topic.path.code, [])
        stream_key = stream_state_key(path, stream_name)

        supervisor = put_in(supervisor.sites[id].streams[stream_key], state)

        Logger.info("RSMP: #{id}: Received stream state #{stream_key}: #{state}")

        pub = %{topic: "stream", site: id, stream: stream_key, state: state}
        Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{supervisor.id}", pub)
        Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{supervisor.id}:#{id}", pub)

        supervisor
    end
  end

  defp receive_stream(supervisor, topic, data) do
    Logger.warning("RSMP: #{topic.id}: Ignoring stream state payload: #{inspect(data)}")
    supervisor
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

  def module(supervisor, name), do: supervisor.modules |> Map.fetch!(name)
  def commander(supervisor, name), do: module(supervisor, name).commander()
  def converter(supervisor, name), do: module(supervisor, name).converter()

  def from_rsmp_status(supervisor, path, data) do
    converter(supervisor, path.module).from_rsmp_status(path.code, data)
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

  defp maybe_put_status_seq(status, current_status, _stream_name, incoming_seq) do
    seq = incoming_seq || status_seq(current_status)
    maybe_put_seq(status, seq)
  end

  defp extract_status_envelope(data) when is_map(data) do
    type = map_get_any(data, ["type", :type, "t", :t])
    seq = map_get_any(data, ["seq", :seq, "s", :s])
    inner_data = map_get_any(data, ["data", :data, "d", :d])

    cond do
      not is_nil(inner_data) and not is_nil(type) ->
        {type, seq, inner_data}

      not is_nil(inner_data) ->
        {"full", seq, inner_data}

      true ->
        {"full", seq, data}
    end
  end

  defp extract_status_envelope(data), do: {"full", nil, data}

  defp map_get_any(map, keys) do
    Enum.find_value(keys, fn key ->
      Map.get(map, key)
    end)
  end

  defp status_seq(value) when is_map(value) do
    Map.get(value, "seq") || Map.get(value, :seq)
  end

  defp status_seq(_value), do: nil


  defp stream_state_key(path, stream_name) do
    normalized_stream =
      case stream_name do
        nil -> "default"
        "" -> "default"
        other -> to_string(other)
      end

    "#{to_string(path)}/#{normalized_stream}"
  end

  def to_rsmp_status(supervisor, path, data) do
    converter(supervisor, path.module).to_rsmp_status(path.code, data)
  end
end
