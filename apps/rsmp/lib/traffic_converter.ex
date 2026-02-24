defmodule RSMP.Converter.Traffic do
  @behaviour RSMP.Converter

  @impl RSMP.Converter
  def aggregation_zero(), do: %{cars: 0, bicycles: 0, busses: 0}

  # convert from internal format to sxl format

  @impl RSMP.Converter
  def to_rsmp_status("volume", data) when is_map(data) do
    data
    |> normalize_string_keys()
    |> keep_allowed_keys()
    |> drop_zero_values()
  end

  def to_rsmp_status(_code, data) when is_map(data), do: data

  # convert from sxl format to internal format

  @impl RSMP.Converter
  def from_rsmp_status("volume", data) when is_map(data) do
    data
    |> normalize_string_keys()
    |> keep_allowed_keys()
    |> Enum.into(%{}, fn {key, value} -> {String.to_atom(key), value} end)
  end

  def from_rsmp_status(_code, data) when is_map(data), do: data

  # setup default command values from statuses

  @impl RSMP.Converter
  def command_default(_code, _statuses), do: %{}

  defp normalize_string_keys(data) do
    Enum.into(data, %{}, fn {key, value} -> {to_string(key), value} end)
  end

  defp keep_allowed_keys(data) do
    Map.take(data, ["cars", "bicycles", "busses"])
  end

  defp drop_zero_values(data) do
    data
    |> Enum.reject(fn {_key, value} -> value == 0 or is_nil(value) end)
    |> Enum.into(%{})
  end
end
