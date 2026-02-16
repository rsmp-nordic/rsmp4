defmodule RSMP.Converter.TLC do
  @behaviour RSMP.Converter

  # convert from internal format to sxl format
  def to_rsmp_status("groups", data) do
    %{
      "basecyclecounter" => data.base,
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
    %{
      base: data["basecyclecounter"],
      cycle: data["cyclecounter"],
      groups: data["signalgroupstatus"],
      stage: data["stage"]
    }
  end

  def from_rsmp_status("plan", data) do
    %{
      plan: data["status"],
      source: data["source"]
    }
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
end
