# RSMP Node
# Acts as a GenServer and has the MQTT connection. 
# Message handling and behaviour are delegated to Services and Managers.

defmodule RSMP.Node do
  defmodule Builder do
    @callback services() :: list( RSMP.Service.t )
    @callback managers() :: list( RSMP.Manager.t )
    @callback start() :: RSMP.Node.t
  end

  use GenServer

  defstruct(
    id: nil,
    builder: nil,
    mqtt: nil,
    services: %{},
    remotes: %{}
  )

  def new(options), do: __struct__(options)

  # api

  def start(id: id, builder: builder, services: services) do
    {:ok, node} = GenServer.start_link(RSMP.Node, id: id, builder: builder, services: services)
    node
  end

  def status(node, path) do
    GenServer.call(node,{:status, path})
  end

  def command(node, path, payload, properties) do
    GenServer.cast(node,{:status,path, payload, properties})
  end

  def mapping(modules) do
    for module <- modules, into: %{}, do: {RSMP.Service.name(module), module}
  end

  # callbacks

  @impl GenServer
  def init(id: id, builder: builder, services: services) do
    node = new(id: id, builder: builder, services: services)
    {:ok, node}
  end

  @impl GenServer
  def handle_call({:status, path}, _from, node) do
    status = node.services[path.module] |> RSMP.Service.status(path.code)
    {:reply, status, node}
  end

  @impl GenServer
  def handle_cast({:command, path, payload, properties}, node) do
    node = get_and_update_in(node.services[path.module], fn(service) -> RSMP.Service.command(service, path, payload, properties) end )
    {:noreply, node }
  end

  # implementation

  def publish_status(node, service, path) do
    path_string = Path.to_string(path)
    value = service.statuses[path_string]
    Logger.info("RSMP: Sending status: #{path_string} #{Kernel.inspect(value)}")
    status = to_rsmp_status(service, path, value)
    topic = Topic.new(id: node.id, type: "status", path: path)

    :emqtt.publish_async(
      node.mqtt,
      Topic.to_string(topic),
      Utility.to_payload(status),
      [retain: true, qos: 1],
      &publish_done/1
    )
  end

  def publish_alarm(node, service, path) do
    flags = alarm_flag_string(node, path)
    path_string = Path.to_string(path)
    Logger.info("RSMP: Sending alarm: #{path_string} #{flags}")

    :emqtt.publish_async(
      node.pid,
      "#{site.id}/alarm/#{path_string}",
      Utility.to_payload(Map.from_struct(node.alarms[path_string])),
      [retain: true, qos: 1],
      &publish_done/1
    )
  end
end

