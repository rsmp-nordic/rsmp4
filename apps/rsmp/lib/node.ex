defmodule RSMP.Node do
  use Supervisor

  def start_link(id, services) do
    Supervisor.start_link(__MODULE__, {id, services}, name: RSMP.Registry.via(id, :node))
  end

  @impl Supervisor
  def init({id, services}) do
    services =
      for {component, module, args} <- services do
        name = module.name()
        Supervisor.child_spec({module, {id, component, name, args}}, id: {component, name})
      end

    helpers = [
      {RSMP.Connection, id},
      {
        DynamicSupervisor,
        name: RSMP.Registry.via(id, :remote_supervisor, id), strategy: :one_for_one
      }
    ]

    Supervisor.init(helpers ++ services, strategy: :one_for_one)
  end
end
