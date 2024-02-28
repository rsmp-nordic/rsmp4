defmodule RSMP.Converter.Traffic do
  @behaviour RSMP.Converter


  # convert from internal format to sxl format

  def to_rsmp_status("201", data) do
    %{
      "starttime" => data.starttime,
      "vehicles" => data.vehicles
    }
  end

  # convert from sxl format to internal format

  def from_rsmp_status("201", data) do
    %{
      starttime: data["starttime"],
      vehicles: data["vehicles"]
    }
  end

end
