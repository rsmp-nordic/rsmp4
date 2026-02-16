defmodule RSMP.Converter.TLC do
  @behaviour RSMP.Converter

  # convert from internal format to sxl format
  def to_rsmp_status("groups", data) do
    %{
      "cyclecounter" => data.cycle,
      "signalgroupstatus" => data.groups,
      "stage" => data.stage
    }
  end

  def to_rsmp_status("plan", data) do
    %{
      "status" => data.plan,
      "source" => data.source
    }
  end

  def to_rsmp_status("plans", data) do
    items =
      data
      |> Enum.join(",")

    %{"status" => items}
  end

  def to_rsmp_status("24", data) do
    items =
      data
      |> Enum.map(fn {plan, value} -> "#{plan}-#{value}" end)
      |> Enum.join(",")

    %{"status" => items}
  end

  def to_rsmp_status("28", data), do: to_rsmp_status("24", data)

  # convert from sxl format to internal format

  def from_rsmp_status("groups", data) do
    groups = normalize_groups(Map.get(data, "signalgroupstatus"))

    %{}
    |> maybe_put(:cycle, data, "cyclecounter")
    |> maybe_put_value(:groups, groups)
    |> maybe_put(:stage, data, "stage")
  end

  def from_rsmp_status("plan", data) do
    %{}
    |> maybe_put(:plan, data, "status")
    |> maybe_put(:source, data, "source")
  end

  def from_rsmp_status("plans", data) do
    items = String.split(data["status"], ",")

    for item <- items do
      String.to_integer(item)
    end
  end

  def from_rsmp_status("24", data) do
    items = String.split(data["status"], ",")

    for item <- items, into: %{} do
      [plan, value] = String.split(item, "-")
      {String.to_integer(plan), String.to_integer(value)}
    end
  end

  def from_rsmp_status("28", data), do: from_rsmp_status("24", data)

  # setup default command values from statuses

  def command_default("plan.set", statuses) do
    %{
      plan: statuses["tlc.plan"][:plan]
    }
  end

  defp maybe_put(map, _key, data, _source_key) when not is_map(data), do: map

  defp maybe_put(map, key, data, source_key) do
    if Map.has_key?(data, source_key) do
      Map.put(map, key, data[source_key])
    else
      map
    end
  end

  defp maybe_put_value(map, _key, nil), do: map
  defp maybe_put_value(map, key, value), do: Map.put(map, key, value)

  defp normalize_groups(nil), do: nil

  defp normalize_groups(groups) when is_map(groups) do
    groups
    |> Enum.into(%{}, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_groups(groups) when is_binary(groups) do
    groups
    |> String.graphemes()
    |> Enum.with_index(1)
    |> Enum.into(%{}, fn {state, index} -> {Integer.to_string(index), state} end)
  end

  defp normalize_groups(_groups), do: nil
end
