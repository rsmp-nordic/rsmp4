# RSMP Node
# Acts as a GenServer and has the MQTT connection. 
# Message handling and behaviour are delegated to Services and Managers.

defmodule RSMP.Node do
  defmodule Builder do
    @callback start() :: RSMP.Node.t
  end

  use GenServer

  defstruct(
    services: {}
  )

  def new(options \\ %{}), do: __struct__(options)

  # api

  def start(options) do
    {:ok, node} = GenServer.start_link(RSMP.Node, options)
    node
  end

  def status(node, name, code) do
    GenServer.call(node,{:status, name, code})
  end

  def ingoing(node, name, message) do
    GenServer.cast(node,{:status,name,message})
  end

  def mapping(modules) do
    for module <- modules, into: %{}, do: {RSMP.Service.name(module), module}
  end

  # callbacks

  @impl GenServer
  def init(options) do
    node = new(options)
    {:ok, node}
  end

  @impl GenServer
  def handle_call({:status, name, code}, _from, node) do
    status = node.services[name] |> RSMP.Service.status(code)
    {:reply, status, node}
  end

  @impl GenServer
  def handle_cast({:ingoing, name, code, args}, node) do
    service = node.services[name] |> RSMP.Service.ingoing(code, args)
    node = put_in(node.services[name], service)
    {:noreply, node }
  end

end



##################
# previous code

defmodule RSMP.Node do

  defprotocol Builder do
    def name()
    def services()
    def managers()
  end

  defstruct(
    id: nil,
    emqtt: nil,
    services: %{},
    managers: %{}
    remotes: %{}
  )

  @moduledoc false
  use GenServer
  require Logger
  alias RSMP.{Utility, Topic, Path}
  
  def new(options \\ %{}), do: __struct__(options)

  # api

  def start_link(options) do
    GenServer.start_link(__MODULE__, options)
  end

  def id(pid) do
    GenServer.call(pid, :id)
  end

  def services(pid) do
    GenServer.call(pid, :services)
  end

  def managers(pid) do
    GenServer.call(pid, :services)
  end

  def remotes() do
    GenServer.call(pid, :remotes)
  end


  # GenServer callbacks

  @impl GenServer
  def init(id: id, services: services, managers: managers) do
    node =
      new(id: id, services: services, managers: managers) 
      |> setup()
      |> start_mqtt()
      |> subscribe()

    {:ok, node}
  end

  @impl true
  def handle_call(:id, _from, node) do
    {:reply, node.id, node}
  end

  @impl true
  def handle_call(:services, _from, node) do
    {:reply, node.services, node}
  end

  @impl true
  def handle_call({:managers, path}, _from, node) do
    {:reply, node.managers, node}
  end

  @impl true
  def handle_call(:remotes, _from, node) do
    {:reply, node.remotes, node}
  end

  # emqtt callbacks

  @impl :emqtt
  def handle_info({:publish, publish}, site) do
    RSMP.Node.Protocol.handle_publish(node, publish) # dispatch based on type, might end at e.g. RSMP.Node.TLC.receive()
  end


  # implementation

  def setup(node) do
    node
  end

  def start_mqtt(node) do
    Logger.info("RSMP: starting emqtt")
    options =
      Utility.node_options()
      |> Map.merge(%{
        name: String.to_atom(node.id),
        nodeid: node.id,
        will_topic: "#{id}/state",
        will_payload: Utility.to_payload(0),
        will_retain: true
      })

    {:ok, emqtt} = :emqtt.start_link(options)
    {:ok, _} = :emqtt.connect(emqtt)
    Map.put(node, :emqtt, emqtt)
  end   

  def subscribe(node) do
    node
  end

end
