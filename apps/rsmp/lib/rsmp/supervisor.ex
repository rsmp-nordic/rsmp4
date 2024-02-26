defmodule RSMP.Supervisor do
  use GenServer
  require Logger
  import RSMP.Utility

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
        to_payload(plan),
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
      to_payload(%{flag => value}),
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
  def handle_info({:publish, publish}, supervisor) do
    {path, component} = parse_topic(publish.topic)
    handle_publish(path, component, publish, supervisor)
  end

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

  # helpers

  defp handle_publish({id, "state"}, _component, %{payload: payload}, supervisor) do
    online = from_payload(payload) == 1

    client =
      (supervisor.clients[id] || %{statuses: %{}, alarms: %{}, num_alarm: 0})
      |> Map.put(:online, online)

    clients = Map.put(supervisor.clients, id, client)

    # Logger.info("#{id}: Online: #{online}")
    data = %{topic: "clients", clients: clients}
    Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", data)
    {:noreply, %{supervisor | clients: clients}}
  end

  defp handle_publish(
         {id, "result", module, command},
         component,
         %{payload: payload, properties: properties},
         supervisor
       ) do
    response = from_payload(payload)
    command_id = properties[:"Correlation-Data"]

    Logger.info(
      "RSMP: #{id}: Received response to '#{command}' command #{component}/#{module}/#{command_id}: #{inspect(response)}"
    )

    data = %{
      topic: "response",
      response: %{
        id: id,
        command: command,
        command_id: command_id,
        result: response
      }
    }

    Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", data)

    {:noreply, supervisor}
  end

  defp handle_publish(
         {id, "status", module, code},
         component,
         %{payload: payload},
         supervisor
       ) do
    status = from_payload(payload)
    client = supervisor.clients[id] || %{statuses: %{}, alarms: %{}, online: false}

    path = build_path(module, code, component)
    statuses = client[:statuses] |> Map.put(path, status)
    client = %{client | statuses: statuses}
    clients = supervisor.clients |> Map.put(id, client)

    Logger.info("RSMP: #{id}: Received status #{path}: #{inspect(status)} from #{id}")
    data = %{topic: "status", clients: clients}
    Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", data)
    {:noreply, %{supervisor | clients: clients}}
  end

  defp handle_publish(
         {id, "alarm", module, code},
         component,
         %{payload: payload},
         supervisor
       ) do
    status = from_payload(payload)
    client = supervisor.clients[id] || %{statuses: %{}, alarms: %{}, online: false}

    path = build_path(module, code, component)
    alarms = client[:alarms] |> Map.put(path, status)
    client = %{client | alarms: alarms} |> set_client_num_alarms()
    clients = supervisor.clients |> Map.put(id, client)

    Logger.info("RSMP: #{id}: Received alarm #{path}: #{inspect(status)} from #{id}")
    data = %{topic: "alarm", clients: clients}
    Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", data)
    {:noreply, %{supervisor | clients: clients}}
  end

  # catch-all in case old retained messages are received from the broker
  defp handle_publish(path, component, publish, supervisor) do
    Logger.warning(
      "Unhandled publish, path: #{inspect(path)}, component: #{inspect(component)}, publish: #{inspect(publish)}"
    )

    IO.puts(publish.payload)
    {:noreply, supervisor}
  end

  def publish_done(data) do
    Logger.debug("RSMP: Publish result: #{Kernel.inspect(data)}")
  end

  def set_client_num_alarms(client) do
    num =
      client.alarms
      |> Enum.count(fn {_path, alarm} ->
        alarm["active"]
      end)

    client |> Map.put(:num_alarms, num)
  end
end
