defmodule RSMP.Node.TLC do
  def make_site_id(), do: SecureRandom.hex(4)

  def start_link(id) do
    services = [
      {["tc","1"], RSMP.Service.TLC, %{plan: 1}}
    ]
    managers = %{
    }

    RSMP.Node.start_link(id, services, managers)
  end
end
