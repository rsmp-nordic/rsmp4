defprotocol RSMP.Service.Protocol do
  def alarms(node,path)
  def status(node, path)
  def command(node, path, payload, properties)
  def reaction(node, path, payload, properties)
end



defmodule RSMP.Service do
  def alarm_flag_string(service, path) do
    service.alarms(path)
    |> Map.from_struct()
    |> Enum.filter(fn {_flag, value} -> value == true end)
    |> Enum.map(fn {flag, _value} -> flag end)
    |> inspect()
  end

end
