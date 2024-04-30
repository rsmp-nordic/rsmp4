defmodule RSMP.Node do
  use Supervisor

  def start_link(id, services) do
    Supervisor.start_link(__MODULE__, {id,services}, name: RSMP.Registry.via(id))
  end

  @impl Supervisor
  def init({id,services}) do
    children = for {component, module, args} <- services do
      name = module.name()
      Supervisor.child_spec({module, {id,component, name, args}}, id: {component, name})
    end
    connection = {RSMP.Connection, id}
    children = [connection | children]
    Supervisor.init(children, strategy: :one_for_one)
  end
end