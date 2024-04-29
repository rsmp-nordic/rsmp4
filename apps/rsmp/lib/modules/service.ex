defprotocol RSMP.Service.Protocol do
  def action(service)

  def alarms(service,path)
  def status(service, path)
  def command(service, path, payload, properties)
  def reaction(service, path, payload, properties)
end

defmodule RSMP.Service do
  use GenServer

  defstruct(
    module: nil,
    data: nil
  )


  def get(service), do: GenServer.call(service, :get)

  def action(service), do: GenServer.call(service, :action)

  def start_link(module, id, service, data) do
    via = RSMP.Registry.via(id, service)
    GenServer.start_link(__MODULE__, [module, id, service, data], name: via)
  end


  @impl GenServer
  def init([module, _id, _service, data]) do
    {:ok, module.new(data)}
  end

  @impl GenServer
  def handle_call(:get, _from, service), do: {:reply, service, service}

  @impl GenServer
  def handle_call(:action, _from, service) do
    {:reply, RSMP.Service.Protocol.action(service), service}
  end

  def alarm_flag_string(service, path) do
    service.alarms(path)
    |> Map.from_struct()
    |> Enum.filter(fn {_flag, value} -> value == true end)
    |> Enum.map(fn {flag, _value} -> flag end)
    |> inspect()
  end

end
