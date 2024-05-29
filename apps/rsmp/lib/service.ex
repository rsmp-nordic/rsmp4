defprotocol RSMP.Service.Protocol do
  def name(service)
  def id(service)

  def receive_command(service, path, data, properties)
  def receive_reaction(service, path, data, properties)

  def format_status(service, code)
end

defmodule RSMP.Service do
  require Logger

  defmodule Behaviour do
    @type id :: String.t()
    @type data :: Map.t()

    @callback new(id, data) :: __MODULE__
    @callback name() :: String.t()
  end

  # macro
  defmacro __using__(options) do
    # the following code will be injencted into the module using RSMP.Service
    name = Keyword.get(options, :name)

    quote do
      use GenServer
      require Logger
      @behaviour RSMP.Service.Behaviour

      def name(), do: unquote(name)

      def start_link({id, component, service, data}) do
        via = RSMP.Registry.via_service(id, service, component)
        GenServer.start_link(__MODULE__, {id, data}, name: via)
      end

      @impl GenServer
      def init({id, data}) do
        {:ok, new(id, data)}
      end

      @impl GenServer
      def handle_call({:receive_command, topic, data, properties}, _from, service) do
        {service,result} = RSMP.Service.Protocol.receive_command(service, topic, data, properties)
        if result do
          RSMP.Service.publish_result(service, topic.path.code, topic.path.component, result)
        end
        {:reply, result, service}
      end

      @impl GenServer
      def handle_call({:receive_reaction, topic, data, properties}, _from, service) do
        service = RSMP.Service.Protocol.receive_reaction(service, topic, data, properties)
        {:reply, :ok, service}
      end
    end
  end

  # api
  def publish_status(service, code) do
    publish_status(service, code, [])
  end

  def publish_status(service, code, component, properties \\ %{}) do
    topic = make_topic(service, "status", code, component)
    data = RSMP.Service.Protocol.format_status(service, code)
    RSMP.Connection.publish_message(topic.id, topic, data, %{retain: true, qos: 1}, properties)
  end

  def publish_result(service, code, component, data, properties \\ %{}) do
    topic = make_topic(service, "result", code, component)
    RSMP.Connection.publish_message(topic.id, topic, data, %{retain: true, qos: 2}, properties)
  end

  defp make_topic(service, type, code, component) do
    id = RSMP.Service.Protocol.id(service)
    module = RSMP.Service.Protocol.name(service)
    RSMP.Topic.new(id, type, module, code, component)
  end

  #  def alarm_flag_string(service, path) do
  #    service.alarms(path)
  #    |> Map.from_struct()
  #    |> Enum.filter(fn {_flag, value} -> value == true end)
  #    |> Enum.map(fn {flag, _value} -> flag end)
  #    |> inspect()
  #  end
end
