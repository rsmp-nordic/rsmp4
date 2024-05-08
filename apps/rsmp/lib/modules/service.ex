defmodule RSMP.Service do
  require Logger

  defmodule Behaviour do
    @type id :: String.t()
    @type service :: RSMP.Service.t()
    @type path :: RSMP.Path.t()
    @type data :: Map.t()
    @type properties :: Map.t()

    @callback new(id, data) :: __MODULE__

    @callback id(service) :: id
    @callback get_status(service, path) :: any

    @callback converter() :: RSMP.Converter

    @callback receive_command(service, path, data, properties) :: service
    @callback receive_reaction(service, path, data, properties) :: service
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
      def init({id,data}) do
        {:ok, new(id, data)}
      end

      @impl GenServer
      def handle_call({:receive_command, topic, data, properties}, _from, service) do
        receive_command(service, topic, data, properties)
        {:reply, :ok, service}
      end

      @impl GenServer
      def handle_call({:receive_reaction, topic, data, properties}, _from, service) do
        receive_reaction(service, topic, data, properties)
        {:reply, :ok, service}
      end

      def publish_status(service, code) do
        topic = RSMP.Topic.new( id(service), "status", name(), code)
        data = converter().to_rsmp_status(topic.path.code, service)
        RSMP.Service.publish_status(topic, data)
      end

    end
  end

  def publish_status(topic, data) do
    Logger.info("RSMP: Sending status: #{topic} #{Kernel.inspect(data)}")
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
