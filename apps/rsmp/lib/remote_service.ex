defprotocol RSMP.Remote.Service.Protocol do
  def name(service)
  def id(service)

  def receive_status(service, path, data, properties)
  #def format_status(service, code)
end

defmodule RSMP.Remote.Service do
  require Logger

  defmodule Behaviour do
    @type id :: String.t()
    @type data :: Map.t()

    @callback new(id, data) :: __MODULE__
    @callback name() :: String.t()
  end

  # macro
  defmacro __using__(options) do
    # the following code will be injencted into the module using RSMP.Remote.Service
    name = Keyword.get(options, :name)

    quote do
      use GenServer
      require Logger
      @behaviour RSMP.Remote.Service.Behaviour

      def name(), do: unquote(name)

      def start_link({id, remote_id, service, component, data}) do
        via = RSMP.Registry.via_remote_service(id, remote_id, service, component)
        GenServer.start_link(__MODULE__, {id, data}, name: via)
      end

      @impl GenServer
      def init({id, data}) do
        {:ok, new(id, data)}
      end

      @impl GenServer
      def handle_call({:receive_status, topic, data, properties}, _from, service) do
        {service,result} = RSMP.Remote.Service.Protocol.receive_command(service, topic, data, properties)
        if result do
          RSMP.Remote.Service.publish_result(service, topic.path.code, topic.path.component, result)
        end
        {:reply, result, service}
      end

    end
  end

  # api
  def publish_command(service, code, data) do
    publish_command(service, code, [], data)
  end

  def publish_command(service, code, component, data, properties \\ %{}) do
    topic = make_topic(service, "command", code, component)
    #data = RSMP.Remote.Service.Protocol.format_status(service, code)
    RSMP.Connection.publish_message(topic.id, topic, data, %{retain: false, qos: 2}, properties)
  end

  defp make_topic(service, type, code, component) do
    id = RSMP.Remote.Service.Protocol.id(service)
    module = RSMP.Remote.Service.Protocol.name(service)
    RSMP.Topic.new(id, type, module, code, component)
  end

end
