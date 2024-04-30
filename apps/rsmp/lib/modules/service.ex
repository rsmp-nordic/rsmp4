defmodule RSMP.Service do
  def start_link(module, id, service, data) do
    via = RSMP.Registry.via(id, service)
    GenServer.start_link(module, [id, service, data], name: via)
  end

  def get(id, service) do
    RSMP.Registry.via(id,service) |> GenServer.call(:get)
  end

  def action(id, service, args) do
    RSMP.Registry.via(id,service) |> GenServer.call({:action, args})
  end

  defmacro __using__(_options) do
    # the following code will be injencted into the module using RSMP.Service,
    quote do
      use GenServer

      @impl GenServer
      def init([_id, _service, data]) do
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
