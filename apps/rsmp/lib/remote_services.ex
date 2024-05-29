defmodule RSMP.Remote.Services do
  use Supervisor

  def start_link({id, remote_services}) do
    Supervisor.start_link(__MODULE__, {id, remote_services}, name: RSMP.Registry.via_remote_services(id))
  end

  @impl Supervisor
  def init({id, remote_services}) do
    remote_services =
      for {component, remote_service, args} <- remote_services do
        name = remote_service.name()
        Supervisor.child_spec({remote_service, {id, component, name, args}}, id: {component, name})
      end

    Supervisor.init(remote_services, strategy: :one_for_one)
  end
end
