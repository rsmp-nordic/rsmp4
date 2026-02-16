defmodule RSMP.Remote.Service.TLC do
  use RSMP.Remote.Service, name: "tlc"
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

  @impl RSMP.Remote.Service.Behaviour
  def new(id, data \\ %{}), do: __struct__(Map.merge(data, %{id: id}))
end

defimpl RSMP.Remote.Service.Protocol, for: RSMP.Remote.Service.TLC do
  require Logger

  def name(_service), do: "tlc"
  def id(service), do: service.id

  def receive_status(
        service,
      %RSMP.Topic{path: %RSMP.Path{code: "plan"}=path},
        %{plan: plan, source: source},
        _properties
      ) do
    Logger.info("Remote TLC #{service.id} component #{RSMP.Path.component_string(path)} was switched to plan '#{plan}' by '#{source}'")
    %{service | plan: plan, source: source}
  end

  def receive_status(
        service,
        %RSMP.Topic{path: path},
        data,
        _properties
      ) do
    Logger.warning("Remote TLC #{service.id} component #{RSMP.Path.component_string(path)} send unknown status #{path}: #{inspect(data)}" )
    service
  end

  def receive_alarm(
        service,
        %RSMP.Topic{path: path},
        alarm,
        _properties
      ) do
    component = RSMP.Path.component_string(path)
    # Logger.info("Remote TLC #{service.id} component #{component} alarm #{path.code} updated")
    key = {component, path.code}
    alarms = Map.put(service.alarms, key, alarm)
    %{service | alarms: alarms}
  end

  def parse_alarm(service, code, data) do
    # Assuming data might contain "cId" or we infer component from context?
    # Actually, parse_alarm receives the raw data.
    # The 'receive_alarm' uses RSMP.Path for component.
    # 'data' in parse_alarm comes from RSMP connection payload.
    # Let's trust the logic generated.
    # Note: component is part of the path, but in RSMP message sometimes cId is explicit?
    # RSMP 3 vs 4.

    # Wait, the subagent logic for parse_alarm:
    # component = data["cId"]
    # key = {component, code}
    # alarm = Map.get(service.alarms, key, RSMP.Alarm.new())
    # ...

    # Does 'data' from alarm message contain cId?
    # Usually alarm message has cId, aCode, x, ack, s

    # If the subagent wrote this logic, I should check if it makes sense with how receive_alarm stores it using {component, path.code}.

    component = data["cId"] # If data has cId (Component ID)
    key = {component, code}
    alarm = Map.get(service.alarms, key, RSMP.Alarm.new())
    RSMP.Alarm.update_from_string_map(alarm, data)
  end

  # convert from sxl format to internal format
  def parse_status(_service, "plan", data) do
    %{
      plan: data["status"],
      source: data["source"]
    }
  end

  def parse_status(_service, _code, data) do
    data
  end
end
