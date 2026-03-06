defmodule RSMP.Manager.TLC do
  use RSMP.Manager, name: "tlc"
  require Logger

  defstruct(
    id: nil,
    base: 0,
    cycle: 0,
    groups: "",
    alarms: %{},
    plans: %{},
    stage: 0,
    plan: 0,
    source: ""
  )

  @impl RSMP.Manager.Behaviour
  def new(id, data \\ %{}), do: __struct__(Map.merge(data, %{id: id}))
end

defimpl RSMP.Manager.Protocol, for: RSMP.Manager.TLC do
  require Logger

  def name(_service), do: "tlc"
  def id(service), do: service.id

  def receive_status(
        service,
      %RSMP.Topic{path: %RSMP.Path{code: "tlc.plan"}},
        %{plan: plan, source: source},
        _properties
      ) do
    Logger.debug("Manager: Remote TLC #{service.id} was switched to plan '#{plan}' by '#{source}'")
    %{service | plan: plan, source: source}
  end

  def receive_status(
        service,
        %RSMP.Topic{path: %RSMP.Path{code: "tlc.groups"}},
        data,
        _properties
      ) do
    groups = data["signalgroupstatus"] || data[:signalgroupstatus] || %{}
    %{service | groups: groups}
  end

  def receive_status(
        service,
        %RSMP.Topic{path: %RSMP.Path{code: "tlc.plans"}},
        _data,
        _properties
      ) do
    service
  end

  def receive_status(
        service,
        %RSMP.Topic{path: path},
        data,
        _properties
      ) do
    Logger.warning("Supervisor: Remote TLC #{service.id} send unknown status #{path}: #{inspect(data)}" )
    service
  end

  def receive_alarm(
        service,
        %RSMP.Topic{path: path},
        {component, alarm},
        _properties
      ) do
    key = {component, path.code}
    alarms = Map.put(service.alarms, key, alarm)
    %{service | alarms: alarms}
  end

  def parse_alarm(service, code, data) do
    component = data["component"] || data["cId"]
    key = {component, code}
    existing = Map.get(service.alarms, key, RSMP.Alarm.new())
    alarm = RSMP.Alarm.update_from_string_map(existing, data)
    {component, alarm}
  end

  # convert from sxl format to internal format
  def parse_status(_service, "tlc.plan", data) do
    %{
      plan: data["status"],
      source: data["source"]
    }
  end

  def parse_status(_service, _code, data) do
    data
  end
end
