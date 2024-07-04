defmodule RSMP.Node.Monitor do
  def start_link(id) do
    services = []
    managers = %{
      "tc" => RSMP.Remote.Service.TLC
    }
    RSMP.Node.start_link(id, services, managers)
  end
end
