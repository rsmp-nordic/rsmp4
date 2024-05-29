defmodule RSMP.Remote.Nodes do
  use DynamicSupervisor

  def start_link(id) do
    DynamicSupervisor.start_link(__MODULE__, [], name: RSMP.Registry.via_remotes(id))
  end

  @impl DynamicSupervisor
  def init(_init_args) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
