defmodule RSMP.Remote.Services do
  use DynamicSupervisor

  def start_link({id, remote_id, remote_services}) do
    DynamicSupervisor.start_link(__MODULE__, {id, remote_id, remote_services}, name: RSMP.Registry.via_remote_services(id, remote_id))
  end

  @impl DynamicSupervisor
  def init({_id, _remote_id, _remote_services}) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
