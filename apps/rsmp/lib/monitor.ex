defmodule RSMP.Node.Monitor do
  @modules [RSMP.Module.TLC, RSMP.Module.Traffic]

  def start_link(id) do
    services = []
    managers = for mod <- @modules, code <- mod.codes(), into: %{} do
      {code, %{manager: mod.manager(), service_name: mod.name()}}
    end
    RSMP.Node.start_link(id, services, managers, [type: :supervisor])
  end
end
