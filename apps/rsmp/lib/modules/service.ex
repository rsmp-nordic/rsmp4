defmodule RSMP.Service do
  def get(id, service) do
    RSMP.Registry.via(id,service) |> GenServer.call(:get)
  end

  def action(id, service) do
    RSMP.Registry.via(id,service) |> GenServer.call(:action)
  end

  defmacro __using__(_options) do
    quote do
      use GenServer

      def start_link(id, service, data) do
        via = RSMP.Registry.via(id, service)
        GenServer.start_link(__MODULE__, [id, service, data], name: via)
      end 
      
      @impl GenServer
      def init([_id, _service, data]) do
        {:ok, new(data)}
      end

      @impl GenServer
      def handle_call(:get, _from, service), do: {:reply, service, service}

      @impl GenServer
      def handle_call(:action, _from, service) do
        {:reply, action(service), service}
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
