defmodule RSMP.Supervisor do
  use GenServer
  require Logger
  alias RSMP.{Utility,Topic,Path}

  defstruct(
    pid: nil,
    id: nil,
    clients: %{}
  )

  def new(options \\ %{}), do: __struct__(options)

  # api

  def start_link(options) do
    GenServer.start_link(__MODULE__, options, name: __MODULE__)
  end

  def client_ids() do
    GenServer.call(__MODULE__, :client_ids)
  end

  def clients() do
    GenServer.call(__MODULE__, :clients)
  end

  def client(id) do
    GenServer.call(__MODULE__, {:client, id})
  end

  def set_plan(client_id, plan) do
    GenServer.cast(__MODULE__, {:set_plan, client_id, plan})
  end

  def set_alarm_flag(client_id, path, flag, value) do
    GenServer.cast(__MODULE__, {:set_alarm_flag, client_id, path, flag, value})
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
  def handle_call(:client_ids, _from, supervisor) do
    {:reply, Map.keys(supervisor.clients), supervisor}
  end

  @impl true
  def handle_call(:clients, _from, supervisor) do
    {:reply, supervisor.clients, supervisor}
  end

  @impl true
  def handle_call({:client, id}, _from, supervisor) do
    {:reply, supervisor.clients[id], supervisor}
  end

  @impl true
  def handle_cast({:set_plan, client_id, plan}, supervisor) do
    # Send command to device
    # set current time plan
    path = "tlc/2"
    topic = "#{client_id}/command/#{path}"
    command_id = SecureRandom.hex(2)

    Logger.info(
      "RSMP: Sending '#{path}' command #{command_id} to #{client_id}: Please switch to plan #{plan}"
    )

    properties = %{
      "Response-Topic": "#{client_id}/result/#{path}",
      "Correlation-Data": command_id
    }

    # Logger.info("response/#{client_id}/#{topic}")

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
  def handle_cast({:set_alarm_flag, client_id, path, flag, value}, supervisor) do
    supervisor = put_in(supervisor.clients[client_id].alarms[path][flag], value)

    # Send alarm flag to device
    topic = "#{client_id}/reaction/#{path}"

    Logger.info("RSMP: Sending alarm flag #{path} to #{client_id}: Set #{flag} to #{value}")

    :emqtt.publish_async(
      supervisor.pid,
      topic,
      Utility.to_payload(%{flag => value}),
      [retain: true, qos: 1],
      &publish_done/1
    )

    {:noreply, supervisor}

    data = %{
      topic: "alarm",
      id: client_id,
      path: path,
      alarm: supervisor.clients[client_id].alarms[path]
    }

    Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", data)

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
    online = data == 1

    client =
      (supervisor.clients[id] || new_site())
      |> Map.put(:online, online)

    clients = Map.put(supervisor.clients, id, client)

    # Logger.info("#{id}: Online: #{online}")
    pub = %{topic: "clients", clients: clients}
    Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", pub)
    %{supervisor | clients: clients}
  end

  defp receive_result(supervisor, topic, result, command_id) do
    Logger.info(
      "RSMP: #{topic.id}: Received result to '#{topic.code}' command #{Path.to_string(topic.path)}: #{inspect(result)}"
    )

    pub = %{
      topic: "response",
      response: %{
        id: topic.id,
        module: topic.path.module,
        command: topic.code,
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
    supervisor =
      if supervisor.clients[id],
        do: supervisor,
        else: put_in(supervisor.clients[id], new_site())

    client = supervisor.clients[id]
    converter = converter(client, topic.path.module)
    status = converter.from_rsmp_status(client, path, data)
    supervisor = put_in(supervisor.clients[id].statuses[path], status)

    Logger.info("RSMP: #{id}: Received status #{path}: #{inspect(status)} from #{id}")
    pub = %{topic: "status", clients: supervisor.clients}
    Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", pub)

    supervisor
  end

  defp receive_alarm(supervisor, topic, alarm) do
    id = topic.id
    path = topic.path
    client = supervisor.clients[id] || new_site()

    alarms = client.alarms |> Map.put(Path.to_string(topic.path), alarm)
    client = %{client | alarms: alarms} |> set_site_num_alarms()
    clients = supervisor.clients |> Map.put(id, client)

    Logger.info("RSMP: #{topic.id}: Received alarm #{path}: #{inspect(alarm)}")
    pub = %{topic: "alarm", clients: clients}
    Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", pub)

    %{supervisor | clients: clients}
  end

  # catch-all in case old retained messages are received from the broker
  defp receive_unknown(supervisor, topic, publish) do
    Logger.warning("Unhandled publish, path: #{inspect(topic)}, publish: #{inspect(publish)}")
    {:noreply, supervisor}
  end

  def publish_done(data) do
    Logger.debug("RSMP: Publish result: #{Kernel.inspect(data)}")
  end

  defp new_site() do
    RSMP.Site.new()
    |> Map.merge(%{
      online: false,
      modules: %{
        "tlc" => RSMP.Commander.TLC,
        "traffic" => RSMP.Commander.Traffic
      },
      statuses: %{},
      alarms: %{}
    })
  end

  def set_site_num_alarms(client) do
    num =
      client.alarms
      |> Enum.count(fn {_path, alarm} ->
        alarm["active"]
      end)

    client |> Map.put(:num_alarms, num)
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
