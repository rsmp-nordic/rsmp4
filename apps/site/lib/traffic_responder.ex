defmodule RSMP.Responder.Traffic do
  @behaviour RSMP.Responder

  def receive_command(client, _code, _component, _data), do: client
  def receive_reaction(client, _code, _component, _data), do: client

  # export status from internal format to sxl format
  def to_rsmp_status("201", data) do
    %{
      "starttime" => data.starttime,
      "vehicles" => data.vehicles
    }
  end

end
