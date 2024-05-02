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
    via = RSMP.Registry.via(id, __MODULE__)
    GenServer.start_link(__MODULE__, id, name: via)
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

  # emqtt
  @impl true
  def handle_info({:publish, publish}, connection) do
    topic = RSMP.Topic.from_string(publish.topic)
    data = RSMP.Utility.from_payload(publish[:payload])
    properties = %{
      response_topic: publish[:properties][:"Response-Topic"],
      command_id: publish[:properties][:"Correlation-Data"]
    }
    case RSMP.Registry.lookup(topic.id, topic.path.module, topic.path.component) do
      [{pid, _value}] -> GenServer.call(pid, {:dispatch, topic, data, properties})
      _ -> Logger.warning("No service handling #{RSMP.Topic.to_string(topic)}")
    end
    {:noreply, connection}
  end

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

  # implementation
  def subscribe_to_topics(connection) do
    emqtt = connection.emqtt
    id = connection.id
    # subscribe to commands
    {:ok, _, _} = :emqtt.subscribe(emqtt, {"#{id}/command/#", 1})

    # subscribe to alarm reactions
    {:ok, _, _} = :emqtt.subscribe(emqtt, {"#{id}/reaction/#", 1})
  end

# def publish_status(node, path) do
#   service = service(node,path)
#   path_string = Path.to_string(path)
#   value = service.statuses[path_string]
#   Logger.info("RSMP: Sending status: #{path_string} #{Kernel.inspect(value)}")
#   status = RSMP.Service.Plug.to_rsmp_status(service, path, value)
#   topic = Topic.new(id: node.id, type: "status", path: path)

#   :emqtt.publish_async(
#     node.mqtt,
#     Topic.to_string(topic),
#     Utility.to_payload(status),
#     [retain: true, qos: 1],
#     &publish_done/1
#   )
# en

# def publish_alarm(node, path) do
#   flags = RSMP.Service.alarm_flag_string(node, path)
#   path_string = Path.to_string(path)
#   Logger.info("RSMP: Sending alarm: #{path_string} #{flags}")

#   :emqtt.publish_async(
#     node.pid,
#     "#{node.id}/alarm/#{path_string}",
#     Utility.to_payload(Map.from_struct(node.alarms[path_string])),
#     [retain: true, qos: 1],
#     &publish_done/1
#   )
# end

# def publish_response(node, path, response: response, properties: properties) do
#   Logger.info("RSMP: Sending result: #{Path.to_string(path)}, #{inspect(response)}")
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

# def publish_done(data) do
#   Logger.debug("RSMP: Publish result: #{Kernel.inspect(data)}")
# end

# # helpers
# def service(node, path), do: node.services[path.module]
end

