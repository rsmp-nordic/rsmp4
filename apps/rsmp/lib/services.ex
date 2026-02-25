defmodule RSMP.Services do
  use Supervisor

  def start_link({id, services}) do
    Supervisor.start_link(__MODULE__, {id, services}, name: RSMP.Registry.via_services(id))
  end

  @impl Supervisor
  def init({id, services}) do
    services =
      for {service, args} <- services do
        name = service.name()
        Supervisor.child_spec({service, {id, name, args}}, id: name)
      end

    Supervisor.init(services, strategy: :one_for_one)
  end
end
