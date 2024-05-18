defprotocol RSMP.Service.Protocol do
  def name(service)
  def id(service)
  def get_status(service, path)
  def converter(service)

  def receive_command(service, path, data, properties)
  def receive_reaction(service, path, data, properties)
end

defmodule RSMP.Service do
  require Logger

  defmodule Behaviour do
    @type id :: String.t()
    @type data :: Map.t()

    @callback new(id, data) :: __MODULE__
  end

  defmacro __using__(options) do
    # the following code will be injencted into the module using RSMP.Service
    name = Keyword.get(options, :name)

    quote do
      use GenServer
      require Logger
      @behaviour RSMP.Service.Behaviour

      def name(), do: unquote(name)

      def start_link({id, component, service, data}) do
        via = RSMP.Registry.via(id, :service, service, component)
        GenServer.start_link(__MODULE__, {id, data}, name: via)
      end

      @impl GenServer
      def init({id, data}) do
        {:ok, new(id, data)}
      end

      @impl GenServer
      def handle_call({:receive_command, topic, data, properties}, _from, service) do
        RSMP.Service.Protocol.receive_command(service, topic, data, properties)
        {:reply, :ok, service}
      end

      @impl GenServer
      def handle_call({:receive_reaction, topic, data, properties}, _from, service) do
        RSMP.Service.Protocol.receive_reaction(service, topic, data, properties)
        {:reply, :ok, service}
      end
    end
  end

  def publish_status(service, code) do
    id = RSMP.Service.Protocol.id(service)
    name = RSMP.Service.Protocol.name(service)
    topic = RSMP.Topic.new(id, "status", name, code)
    converter = RSMP.Service.Protocol.converter(service)
    data = converter.to_rsmp_status(topic.path.code, service)
    [{pid, _value}] = RSMP.Registry.lookup(topic.id, :connection)
    GenServer.cast(pid, {:publish_status, topic, data})
  end

  #  def alarm_flag_string(service, path) do
  #    service.alarms(path)
  #    |> Map.from_struct()
  #    |> Enum.filter(fn {_flag, value} -> value == true end)
  #    |> Enum.map(fn {flag, _value} -> flag end)
  #    |> inspect()
  #  end
end
