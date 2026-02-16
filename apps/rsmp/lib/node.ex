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

    stream_configs = Keyword.get(options, :streams, [])

    children =
      connection_spec ++
        [
          {RSMP.Services, {id, services}},
          {RSMP.Streams, id},
          {RSMP.Remote.Nodes, id}
        ]

    result = Supervisor.init(children, strategy: :one_for_one)

    # Start streams after supervisor init by scheduling a message
    if stream_configs != [] do
      spawn(fn ->
        # Wait for registry entries to be available
        Process.sleep(100)
        Enum.each(stream_configs, fn {module, config} ->
          RSMP.Streams.start_stream(id, module, config)
        end)
      end)
    end

    result
  end
end
