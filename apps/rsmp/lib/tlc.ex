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
          {"tlc." <> code, data}
        end
      [] -> %{}
    end
  end

  def get_alarms(site_id) do
    case RSMP.Registry.lookup_service(site_id, "tlc", []) do
      [{service_pid, _}] ->
        alarms = RSMP.Service.get_alarms(service_pid)
        for {code, alarm} <- alarms, into: %{} do
          {"tlc." <> code, alarm}
        end
      [] -> %{}
    end
  end

  def set_alarm(site_id, path, flags) do
    code = String.replace_prefix(path, "tlc.", "")
    case RSMP.Registry.lookup_service(site_id, "tlc", []) do
      [{service_pid, _}] ->
        RSMP.Service.set_alarm(service_pid, code, flags)
      [] -> :ok
    end
  end

  def set_plan(site_id, plan) do
    case RSMP.Registry.lookup_service(site_id, "tlc", []) do
      [{service_pid, _}] ->
        path = RSMP.Path.new("tlc", "plan.set")
        topic = %RSMP.Topic{path: path}
        data = %{"plan" => plan}
        GenServer.call(service_pid, {:receive_command, topic, data, %{}})
      [] -> :error
    end
  end
end
