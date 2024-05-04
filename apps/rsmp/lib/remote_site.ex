# RSMP Site
defmodule RSMP.Remote.Site do
  @moduledoc false
  require Logger

  defstruct(
    id: nil,
    online: false,
    modules: %{},
    statuses: %{},
    alarms: %{},
    num_alarms: 0
  )

  # api
  def new(options \\ []) do
    remote = __struct__(options)
    %{remote | modules: module_mapping([RSMP.Module.TLC, RSMP.Module.Traffic])}
  end

  def module(site, name), do: site.modules |> Map.fetch!(name)
  def responder(site, name), do: module(site, name).responder
  def converter(site, name), do: module(site, name).converter

  def from_rsmp_status(site, path, data) do
    converter(site, path.module).from_rsmp_status(path.code, data)
  end

  def to_rsmp_status(site, path, data) do
    converter(site, path.module).to_rsmp_status(path.code, data)
  end

  def module_mapping(module_list) do
    for module <- module_list, into: %{}, do: {module.name, module}
  end
end
