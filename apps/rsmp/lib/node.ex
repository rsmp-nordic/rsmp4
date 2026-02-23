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

    channel_configs = Keyword.get(options, :channels, [])

    children =
      connection_spec ++
        [
          {RSMP.Services, {id, services}},
          {RSMP.Channels, id},
          {RSMP.Remote.Nodes, id}
        ]

    result = Supervisor.init(children, strategy: :one_for_one)

    # Start channels after supervisor init by scheduling a message
    if channel_configs != [] do
      spawn(fn ->
        # Wait for registry entries to be available
        Process.sleep(100)
        Enum.each(channel_configs, fn {module, config} ->
          RSMP.Channels.start_channel(id, module, config)
        end)

        # Report initial values from all services to channels so that even
        # stopped channels have the initial state in their buffer. This
        # ensures that fetch/history responses include the baseline state.
        trigger_initial_reports(id, services)
      end)
    end

    result
  end

  # Report current status values from each service to all channels.
  # Called once after channels are created to seed their buffers with
  # the initial state (e.g. all signal groups at startup).
  defp trigger_initial_reports(id, services) do
    for {component, service_module, _data} <- services do
      module_name = service_module.name()

      case RSMP.Registry.lookup_service(id, module_name, component) do
        [{pid, _}] ->
          statuses = RSMP.Service.get_statuses(pid)

          for {code, values} <- statuses do
            RSMP.Service.report_to_channels(id, module_name, code, values)
          end

        [] ->
          :ok
      end
    end
  end
end
