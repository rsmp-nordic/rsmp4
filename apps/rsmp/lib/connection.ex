defmodule RSMP.Connection do
  use GenServer
  require Logger

  defstruct(
    emqtt: nil,
    id: nil
  )

  def new(options), do: __struct__(options)

  # api
  def start_link(id) do
    via = RSMP.Registry.via(id, :connection)
    GenServer.start_link(__MODULE__, id, name: via)
  end

  def publish_message(id, topic, data, %{}=options) do
    [{pid, _value}] = RSMP.Registry.lookup(id, :connection)
    GenServer.cast(pid, {:publish_message, topic, data, options})
  end

  # GenServer
  @impl GenServer
  def init(id) do
    Logger.info("RSMP: starting emqtt")

    options =
      RSMP.Utility.client_options()
      |> Map.merge(%{
        name: String.to_atom(id),
        clientid: id,
        will_topic: "#{id}/state",
        will_payload: RSMP.Utility.to_payload(0),
        will_retain: true
      })

    {:ok, emqtt} = :emqtt.start_link(options)
    {:ok, _} = :emqtt.connect(emqtt)

    connection = new(emqtt: emqtt, id: id)
    subscribe_to_topics(connection)
    {:ok, connection}
  end

  @impl GenServer
  def handle_cast({:publish_message, topic, data, %{retain: retain, qos: qos}=options}, connection) do
    Logger.info("RSMP: Publishing #{topic} with flags #{inspect(options)}: #{Kernel.inspect(data)}")

    :emqtt.publish_async(
      connection.emqtt,
      to_string(topic),
      RSMP.Utility.to_payload(data),
      [retain: retain, qos: qos],
      &publish_done/1
    )

    {:noreply, connection}
  end

  # emqtt
  @impl true
  def handle_info({:connected, _publish}, connection) do
    Logger.info("RSMP: Connected")
    subscribe_to_topics(connection)
    {:noreply, connection}
  end

  @impl true
  def handle_info({:disconnected, _publish}, connection) do
    Logger.warning("RSMP: Disconnected")
    {:noreply, connection}
  end

  @impl true
  def handle_info({:publish, publish}, connection) do
    topic = RSMP.Topic.from_string(publish.topic)
    data = RSMP.Utility.from_payload(publish[:payload])

    case topic.type do
      "state" ->
        receive_state(connection, topic, data)

      type when type in ["command", "reaction"] ->
        dispatch_to_service(topic, data, publish)

      type when type in ["status", "alarm", "result"] ->
        dispatch_to_remote(connection, topic, data, publish)

      _ ->
        Logger.warning("Igoring unknown command type topic")
    end

    {:noreply, connection}
  end

  # implementation
  def subscribe_to_topics(connection) do
    emqtt = connection.emqtt
    id = connection.id
    # highest qos to be used when sending us messages
    qos = 2

    {:ok, _, _} = :emqtt.subscribe(emqtt, {"#{id}/command/#", qos})
    {:ok, _, _} = :emqtt.subscribe(emqtt, {"#{id}/reaction/#", qos})

    {:ok, _, _} = :emqtt.subscribe(emqtt, {"+/state/#", qos})
    {:ok, _, _} = :emqtt.subscribe(emqtt, {"+/status/#", qos})
    {:ok, _, _} = :emqtt.subscribe(emqtt, {"+/alarm/#", qos})
    {:ok, _, _} = :emqtt.subscribe(emqtt, {"+/result/#", qos})
  end

  def receive_state(connection, topic, %{"online" => _online, "modules" => modules}) do
    unless topic.id == connection.id do
      case RSMP.Registry.lookup(connection.id, :remote, topic.id) do
        [] ->
          Logger.info("Adding remote for #{topic.id} with modules: #{inspect(modules)}")
          via = RSMP.Registry.via(connection.id, :remotes)

          {:ok, _pid} =
            DynamicSupervisor.start_child(via, {RSMP.Remote, {connection.id, topic.id}})

        [{_pid, _}] ->
          Logger.info("Updating remote for #{topic.id} with modules: #{inspect(modules)}")
      end
    end
  end

  def receive_state(_connection, _topic, data) do
    Logger.info("Invalid state topic: #{inspect(data)}")
  end

  def dispatch_to_service(topic, data, publish) do
    properties = %{
      response_topic: publish[:properties][:"Response-Topic"],
      command_id: publish[:properties][:"Correlation-Data"]
    }

    case RSMP.Registry.lookup(topic.id, :service, topic.path.module, topic.path.component) do
      [{pid, _value}] ->
        case topic.type do
           "command" -> GenServer.call(pid, {:receive_command, topic, data, properties})
          "reaction" -> GenServer.call(pid, {:receive_reaction, topic, data, properties})
        end

      _ ->
        Logger.warning("No service handling topic: #{topic}")
    end
  end

  def dispatch_to_remote(connection, topic, data, _publish) do
    case RSMP.Registry.lookup(connection.id, :remote, topic.id) do
      [{pid, _value}] ->
        case topic.type do
          "status" -> GenServer.cast(pid, {:receive_status, topic, data})
        end

      _ ->
        nil
        #  Logger.warning("No remote handling topic")
    end
  end

  # def publish_alarm(node, path) do
  #   flags = RSMP.Service.alarm_flag_string(node, path)
  #   Logger.info("RSMP: Sending alarm: #{path} #{flags}")

  #   :emqtt.publish_async(
  #     node.pid,
  #     "#{node.id}/alarm/#{path_string}",
  #     Utility.to_payload(Map.from_struct(node.alarms[path])),
  #     [retain: true, qos: 1],
  #     &publish_done/1
  #   )
  # end

  # def publish_response(node, path, response: response, properties: properties) do
  #   Logger.info("RSMP: Sending result: #{path}, #{inspect(response)}")
  #   # service, Topic, Properties, Payload, Opts, Timeout, Callback
  #   :emqtt.publish_async(
  #     node.mqtt,
  #     properties[:response_topic],
  #     %{ "Correlation-Data": properties[:command_id] },
  #     Utility.to_payload(response),
  #     [retain: true, qos: 1],
  #     :infinity,
  #     &Node.publish_done/1
  #   )
  # end

  def publish_done(data) do
    Logger.debug("RSMP: Publish result: #{Kernel.inspect(data)}")
  end
end
