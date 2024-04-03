
# Node protocol
defprotocol RSMP.Node.Protocol do
  def handle_publish(node, publish)
end


# RSMP Node
defmodule RSMP.Node do
  @moduledoc false
  require Logger
  alias RSMP.{Utility, Topic, Path}

  defstruct(
    id: nil,
    emqtt: nil,
    services: %{},
    remotes: %{}
  )

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

  def remotes() do
    GenServer.call(pid, :remotes)
  end
 

   # implementations

  @impl GenServer
  def init(id: id, services: services) do
    site =
      new(id: id, services: services) 
      |> setup()
      |> start_mqtt()
      |> subscribe()

    {:ok, site}
  end

  @impl :emqtt
  def handle_info({:publish, publish}, site) do
    RSMP.Node.Protocol.handle_publish(node, publish) # dispatch based on type, might end at e.g. RSMP.Node.TLC.receive()
  end


  # helpers

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


end



# TLC node
defmodule RSMP.Node.TLC do
  defimpl RSMP.Node.Protocol, for: __MODULE__ do
    def services(node) do
      [
        RSMP.Service.TLC,
        RSMP.Service.Traffic
      ]
    end

    def subscribe(node) do
      node
    end

    def handle_publish(node, publish)
      # got an mqtt message
    end
  end
end

# Usage
tlc = RSMP.Node.TLC.new
