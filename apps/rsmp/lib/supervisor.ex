defmodule RSMP.Supervisor do
  use GenServer
  require Logger
  alias RSMP.{Utility,Topic,Path}

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
    emqtt_opts = Application.get_env(:rsmp, :emqtt)
    id = "super_#{SecureRandom.hex(4)}"
    emqtt_opts = emqtt_opts |> Keyword.put(:clientid, id)

    {:ok, pid} = :emqtt.start_link(emqtt_opts)
    {:ok, _} = :emqtt.connect(pid)

    subscribe_to_topics(%{pid: pid, id: id})
    supervisor = new(pid: pid, id: id)
    {:ok, supervisor}
  end

  def subscribe_to_topics(%{pid: pid, id: _id}) do
    # Subscribe to statuses
    {:ok, _, _} = :emqtt.subscribe(pid, "+/status/#")

    # Subscribe to online/offline state
    {:ok, _, _} = :emqtt.subscribe(pid, "+/state/#")

    # Subscribe to alamrs
    {:ok, _, _} = :emqtt.subscribe(pid, "+/alarm/#")

    # Subscribe to our response topics
    {:ok, _, _} = :emqtt.subscribe(pid, "+/result/#")
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
    path = "tlc/2"
    topic = "#{site_id}/command/#{path}"
    command_id = SecureRandom.hex(2)

    Logger.info(
      "RSMP: Sending '#{path}' command #{command_id} to #{site_id}: Please switch to plan #{plan}"
    )

    properties = %{
      "Response-Topic": "#{site_id}/result/#{path}",
      "Correlation-Data": command_id
    }

    # Logger.info("response/#{site_id}/#{topic}")

    :ok =
      :emqtt.publish_async(
        supervisor.pid,
        topic,
        properties,
        Utility.to_payload(plan),
        [retain: true, qos: 1],
        :infinity,
        &publish_done/1
      )

    {:noreply, supervisor}
  end

  @impl true
  def handle_cast({:set_alarm_flag, site_id, path, flag, value}, supervisor) do
    path_string = Path.to_string(path)
    supervisor = put_in(supervisor.sites[site_id].alarms[path_string][flag], value)

    # Send alarm flag to device
    topic = %Topic{id: site_id, type: "reaction", path: path}
    Logger.info("RSMP: Sending alarm flag #{path_string} to #{site_id}: Set #{flag} to #{value}")

    :emqtt.publish_async(
      supervisor.pid,
      Topic.to_string(topic),
      Utility.to_payload(%{flag => value}),
      [retain: true, qos: 1],
      &publish_done/1
    )

    {:noreply, supervisor}

    pub = %{
      topic: "alarm",
      id: site_id,
      path: path,
      alarm: supervisor.sites[site_id].alarms[path_string]
    }
    Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", pub)

    {:noreply, supervisor}
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
        "state" ->
          receive_state(supervisor, topic.id, data)

        "status" ->
          receive_status(supervisor, topic, data)

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
  defp receive_state(supervisor, id, data) do
    {supervisor, site} = get_site(supervisor, id)
    online = data == 1
    site = %{site | online: online}
    supervisor = put_in(supervisor.sites[id], site)
    
    pub = %{topic: "state", site: id}
    Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", pub)
    
    supervisor
  end

  defp receive_result(supervisor, topic, result, command_id) do
    Logger.info(
      "RSMP: #{topic.id}: Received result to '#{topic.path.code}' command #{Path.to_string(topic.path)}: #{inspect(result)}"
    )

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

    Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", pub)

    supervisor
  end

  defp receive_status(supervisor, topic, data) do
    id = topic.id
    path = topic.path
    {supervisor, site} = get_site(supervisor, id)

    status = from_rsmp_status(site, path, data)
    supervisor = put_in(supervisor.sites[id].statuses[Path.to_string(path)], status)

    Logger.info("RSMP: #{id}: Received status #{Path.to_string(path)}: #{inspect(status)} from #{id}")
    pub = %{topic: "status", site: id, status: %{topic.path => status}}
    Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", pub)

    supervisor
  end

  defp receive_alarm(supervisor, topic, alarm) do
    id = topic.id
    path_string = Path.to_string(topic.path)
    {supervisor, site} = get_site(supervisor, id)
    alarms = site.alarms |> Map.put(path_string, alarm)
    site = %{site | alarms: alarms} |> set_site_num_alarms()
    supervisor = put_in(supervisor.sites[id], site)

    Logger.info("RSMP: #{topic.id}: Received alarm #{path_string}: #{inspect(alarm)}")
    pub = %{topic: "alarm", alarm: %{topic.path => alarm}}
    Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", pub)

    supervisor
  end

  # catch-all in case old retained messages are received from the broker
  defp receive_unknown(supervisor, topic, publish) do
    Logger.warning("Unhandled publish, topic: #{inspect(topic)}, publish: #{inspect(publish)}")
    {:noreply, supervisor}
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

  defp get_site(supervisor,id) do
    supervisor = if supervisor.sites[id],
      do: supervisor,
      else: put_in(supervisor.sites[id], RSMP.Remote.Site.new(id: id))
    {supervisor, supervisor.sites[id]}
  end

  def module(supervisor, name), do: supervisor.modules |> Map.fetch!(name)
  def commander(supervisor, name), do: module(supervisor, name).commander
  def converter(supervisor, name), do: module(supervisor, name).converter

  def from_rsmp_status(supervisor, path, data) do
    converter(supervisor, path.module).from_rsmp_status(path.code, data)
  end

  def to_rsmp_status(supervisor, path, data) do
    converter(supervisor, path.module).to_rsmp_status(path.code, data)
  end
end
