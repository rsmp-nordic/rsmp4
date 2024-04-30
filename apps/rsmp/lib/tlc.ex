defmodule RSMP.Node.TLC do

  def start_link(id) do
    services = [
      {RSMP.Service.TLC, %{plan: 1}}
    ]
    RSMP.Node.start_link(id, services)
  end
end