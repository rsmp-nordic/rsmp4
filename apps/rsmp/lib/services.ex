defmodule RSMP.Services do
  use Supervisor

  def start_link({id, services}) do
    Supervisor.start_link(__MODULE__, {id, services}, name: RSMP.Registry.via(id, :services))
  end

  @impl Supervisor
  def init({id, services}) do
    services =
      for {component, service, args} <- services do
        name = service.name()
        Supervisor.child_spec({service, {id, component, name, args}}, id: {component, name})
      end
    Supervisor.init(services, strategy: :one_for_one)
  end
end
