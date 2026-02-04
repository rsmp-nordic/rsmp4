defmodule RSMP.Node do
  use Supervisor

  def start_link(id, services, managers, options \\ []) do
    Supervisor.start_link(__MODULE__, {id, services, managers, options}, name: RSMP.Registry.via_node(id))
  end

  @impl Supervisor
  def init({id, services, managers, options}) do
    connection_spec =
      case Keyword.get(options, :connection_module, RSMP.Connection) do
        nil -> []
        module -> [{module, {id, managers, options}}]
      end

    children =
      connection_spec ++
        [
          {RSMP.Services, {id, services}},
          {RSMP.Remote.Nodes, id}
        ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
