defmodule RSMP.Node.Monitor do
  @modules [RSMP.Module.TLC, RSMP.Module.Traffic]

  def child_spec(id) do
    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [id]},
      type: :supervisor
    }
  end

  def start_link(id) do
    services = []
    managers = for mod <- @modules, code <- mod.codes(), into: %{} do
      {code, %{manager: mod.manager(), service_name: mod.name()}}
    end
    RSMP.Node.start_link(id, services, managers, [type: :supervisor])
  end
end
