defmodule RSMP.Node.Hub do
  def start_link(id) do
    services = []
    RSMP.Node.start_link(id, services)
  end
end
