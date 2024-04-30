defmodule RSMP.Service do


  def get(id, service) do
    RSMP.Registry.via(id,service) |> GenServer.call(:get)
  end

  def action(id, service, args) do
    RSMP.Registry.via(id,service) |> GenServer.call({:action, args})
  end

  defmacro __using__(options) do
    # the following code will be injencted into the module using RSMP.Service
    name = Keyword.get(options, :name)

    quote do
      use GenServer

      def name(), do: unquote(name)

      def start_link({id, component, service, data}) do
        via = RSMP.Registry.via(id, component, service)
        GenServer.start_link(__MODULE__, data, name: via)
      end

      @impl GenServer
      def init(data) do
        {:ok, new(data)}
      end

      @impl GenServer
      def handle_call(:get, _from, service), do: {:reply, service, service}

      @impl GenServer
      def handle_call({:action, args}, _from, service) do
        {:ok, service} = action(service, args)
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
