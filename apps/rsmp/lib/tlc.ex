defmodule RSMP.Node.TLC do
  def make_site_id(), do: SecureRandom.hex(4)

  def start_link(id, options \\ []) do
    services = [
      {[], RSMP.Service.TLC, %{plan: 1}}
    ]
    managers = %{
    }

    RSMP.Node.start_link(id, services, managers, options)
  end

  def get_statuses(site_id) do
    case RSMP.Registry.lookup_service(site_id, "tlc", []) do
      [{service_pid, _}] ->
        statuses = RSMP.Service.get_statuses(service_pid)
        for {code, data} <- statuses, into: %{} do
          data = RSMP.Converter.TLC.from_rsmp_status(code, data)
          {"tlc/" <> code, data}
        end
      [] -> %{}
    end
  end
end
