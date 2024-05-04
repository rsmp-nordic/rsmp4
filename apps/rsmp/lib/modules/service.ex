defmodule RSMP.Service do
  require Logger

  defmodule Behaviour do
    @type service :: RSMP.Service.t()
    @type path :: RSMP.Path.t()
    @type data :: Map.t()
    @type properties :: Map.t()

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
        via = RSMP.Registry.via(:service, id, service, component)
        GenServer.start_link(__MODULE__, data, name: via)
      end

      @impl GenServer
      def init(data) do
        {:ok, new(data)}
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
    end
  end

  #  def alarm_flag_string(service, path) do
  #    service.alarms(path)
  #    |> Map.from_struct()
  #    |> Enum.filter(fn {_flag, value} -> value == true end)
  #    |> Enum.map(fn {flag, _value} -> flag end)
  #    |> inspect()
  #  end
end
