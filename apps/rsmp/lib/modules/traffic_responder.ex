defmodule RSMP.Responder.Traffic do
  @behaviour RSMP.Responder

  def receive_command(site, _path, _data, _properties), do: site
  def receive_reaction(site, _path, _data, _properties), do: site
  def receive_alarm(site, _path, _data, _properties), do: site
end
