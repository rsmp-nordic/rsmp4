defmodule RSMP.Connection do
  use GenServer
  require Logger

  defstruct(
    emqtt: nil
  )

  def new(options), do: __struct__(options)

  # api
  def start_link(id) do
    via = RSMP.Registry.via(id, __MODULE__)
    GenServer.start_link(__MODULE__, id, name: via)
  end

  # callbacks

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
    {:ok, new(emqtt: emqtt)}
  end

  # implementation

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

