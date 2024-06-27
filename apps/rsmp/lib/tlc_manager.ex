defmodule RSMP.Remote.Service.TLC do
  use RSMP.Remote.Service, name: "tlc"
  require Logger

  defstruct(
    id: nil,
    base: 0,
    cycle: 0,
    groups: [],
    plans: %{},
    stage: 0,
    plan: 0,
    source: ""
  )

  @impl RSMP.Remote.Service.Behaviour
  def new(id, data \\ []), do: __struct__(Map.merge(data, %{id: id}))
end

defimpl RSMP.Remote.Service.Protocol, for: RSMP.Remote.Service.TLC do
  require Logger

  def name(_service), do: "tlc"
  def id(service), do: service.id

  def receive_status(
        service,
        %RSMP.Topic{path: %RSMP.Path{code: "14"}},
        %{plan: plan, source: source},
        _properties
      ) do
    Logger.info("RSMP: Remote TLC #{service.id} was switched to plan '#{plan}' by '#{source}'")
    %{service | plan: plan, source: source}
  end

  def receive_command(
        service,
        %RSMP.Topic{path: path},
        params,
        _properties
      ) do
    Logger.warning("Unknown status #{path}: #{inspect(params)}" )
    service
  end    

  # convert from sxl format to internal format
  def parse_status(_service, "14", data) do
    %{
      plan: data["status"],
      source: data["source"]
    }
  end

end
