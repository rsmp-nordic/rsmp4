defmodule RSMP.Supervisor do
  use GenServer
  require Logger
  alias RSMP.{Utility, Topic}

  defstruct(
    pid: nil,
    id: nil,
    sites: %{}
  )

  def new(options \\ %{}), do: __struct__(options)

  # api

  def start_link(options) do
    GenServer.start_link(__MODULE__, options, name: __MODULE__)
  end

  def site_ids() do
    GenServer.call(__MODULE__, :site_ids)
  end

  def sites() do
    GenServer.call(__MODULE__, :sites)
  end

  def site(id) do
    GenServer.call(__MODULE__, {:site, id})
  end

  def set_plan(site_id, plan) do
    GenServer.cast(__MODULE__, {:set_plan, site_id, plan})
  end

  def set_alarm_flag(site_id, path, flag, value) do
    GenServer.cast(__MODULE__, {:set_alarm_flag, site_id, path, flag, value})
  end

  # Callbacks

  @impl true
  def init(_rsmp) do
    Logger.info("RSMP: Supervisor GenServer init")
    Process.flag(:trap_exit, true)

    if Application.get_env(:rsmp, :emqtt_connect, true) do
      emqtt_opts = Application.get_env(:rsmp, :emqtt)
      id = "super_#{SecureRandom.hex(4)}"
      emqtt_opts = emqtt_opts |> Keyword.put(:clientid, id)

      Logger.info("RSMP: Starting emqtt with options: #{inspect(emqtt_opts)}")
      {:ok, pid} = :emqtt.start_link(emqtt_opts)
      # {:ok, _} = :emqtt.connect(pid)

      # subscribe_to_topics(%{pid: pid, id: id})
      supervisor = new(pid: pid, id: id)
      send(self(), :connect)
      {:ok, supervisor}
    else
      {:ok, new(id: "test_supervisor")}
    end
  end

  @impl true
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
  def handle_cast({:set_alarm_flag, site_id, path, flag, value}, supervisor) do
    path_string = to_string(path)
    supervisor = put_in(supervisor.sites[site_id].alarms[path_string][flag], value)

    # Send alarm flag to device
    topic = %Topic{id: site_id, type: "reaction", path: path}
    Logger.info("RSMP: Sending alarm flag #{path_string} to #{site_id}: Set #{flag} to #{value}")

    :emqtt.publish_async(
      supervisor.pid,
      to_string(topic),
      Utility.to_payload(%{flag => value}),
      [retain: true, qos: 1],
      &publish_done/1
    )

    pub = %{
      topic: "alarm",
      id: site_id,
      path: path,
      alarm: supervisor.sites[site_id].alarms[path_string]
    }

    Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor", pub)
    Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{site_id}", pub)

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
    Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor", pub)
    Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{id}", pub)

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

    Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor", pub)
    Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{topic.id}", pub)

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
    Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor", pub)
    Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{id}", pub)

    supervisor
  end

  defp receive_alarm(supervisor, topic, data) do
    alarm = %{
      "active" => data["aSt"] == "Active",
      "acknowledged" => data["ack"],
      "blocked" => data["sS"]
    }

    id = topic.id
    path_string = to_string(topic.path)
    {supervisor, site} = get_site(supervisor, id)
    alarms = site.alarms |> Map.put(path_string, alarm)
    site = %{site | alarms: alarms} |> set_site_num_alarms()
    supervisor = put_in(supervisor.sites[id], site)

    Logger.info("RSMP: #{topic.id}: Received alarm #{path_string}: #{inspect(alarm)}")
    pub = %{topic: "alarm", alarm: %{topic.path => alarm}}
    Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor", pub)
    Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{id}", pub)

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

  defp maybe_put_seq(status, _seq), do: status

  defp maybe_put_status_seq(status, current_status, nil, incoming_seq) do
    seq = incoming_seq || status_seq(current_status)
    maybe_put_seq(status, seq)
  end

  defp maybe_put_status_seq(status, current_status, stream_name, incoming_seq) do
    seq = incoming_seq || status_seq_for_stream(current_status, stream_name)

    if is_nil(seq) do
      status
    else
      seq_map =
        current_status
        |> status_seq_map()
        |> Map.put(stream_name, seq)

      maybe_put_seq(status, seq_map)
    end
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

  defp status_seq_for_stream(value, stream_name) do
    case status_seq(value) do
      seq when is_map(seq) ->
        Map.get(seq, stream_name) || Map.get(seq, to_string(stream_name))

      seq ->
        seq
    end
  end

  defp status_seq_map(value) do
    case status_seq(value) do
      seq when is_map(seq) ->
        Enum.into(seq, %{}, fn {key, value} -> {to_string(key), value} end)

      _ ->
        %{}
    end
  end

  def to_rsmp_status(supervisor, path, data) do
    converter(supervisor, path.module).to_rsmp_status(path.code, data)
  end
end
