defmodule RSMP.Managers do
  use DynamicSupervisor

  def start_link({id, remote_id, managers}) do
    DynamicSupervisor.start_link(__MODULE__, {id, remote_id, managers}, name: RSMP.Registry.via_managers(id, remote_id))
  end

  @impl DynamicSupervisor
  def init({_id, _remote_id, _managers}) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
