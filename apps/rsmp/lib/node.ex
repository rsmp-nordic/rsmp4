defmodule RSMP.Node do
  use Supervisor

  def start_link(id, services) do
    Supervisor.start_link(__MODULE__, {id, services}, name: RSMP.Registry.via_node(id))
  end

  @impl Supervisor
  def init({id, services}) do
    children = [
      {RSMP.Connection, id},
      {RSMP.Services, {id, services}},
      {RSMP.Remote.Nodes, id}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
