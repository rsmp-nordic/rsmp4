defmodule RSMP.Node.Monitor do
  def start_link(id) do
    services = []
    managers = %{
      "tlc" => RSMP.Remote.Service.TLC
    }
    RSMP.Node.start_link(id, services, managers)
  end
end
