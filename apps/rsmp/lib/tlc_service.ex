defmodule RSMP.Service.TLC do
  use RSMP.Service, name: "tlc"
  require Logger

  @impl true
  def status_codes(), do: ["groups", "plan", "plans"]

  @impl true
  def alarm_codes(), do: ["hardware.error", "hardware.warning"]

  defstruct(
    id: nil,
    base: 0,
    cycle: 0,
    groups: [],
    plans: %{
      1 => %{},
      2 => %{}
    },
    stage: 0,
    plan: 0,
    source: "startup",
    alarms: %{}
  )

  @impl RSMP.Service.Behaviour
  def new(id, data \\ []) do
     alarms =
       for code <- alarm_codes(), into: %{} do
         {code, RSMP.Alarm.new()}
       end

     __struct__(Map.merge(data, %{id: id, alarms: alarms}))
  end
end

defimpl RSMP.Service.Protocol, for: RSMP.Service.TLC do
  require Logger

  def name(_service), do: "tlc"
  def id(service), do: service.id

  def get_status(service, %RSMP.Path{code: "plan"}) do
    service.plan
  end

  def receive_command(
        service,
      %RSMP.Topic{path: %RSMP.Path{code: "plan.set"}},
        %{"plan" => plan},
        _properties
      ) do

     cond do
      plan == service.plan ->
        msg = "Switching to plan #{plan} skipped: Already in use"
        Logger.info("RSMP: #{msg}")
        Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp:#{service.id}", %{topic: "command_log", id: "tlc.plan.set", message: msg})
        {service, %{status: "already", plan: plan, reason: "Already using plan #{plan}"}}

      service.plans[plan] != nil ->
        msg = "Switching to plan #{plan}"
        Logger.info("RSMP: #{msg}")
        Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp:#{service.id}", %{topic: "command_log", id: "tlc.plan.set", message: msg})
        service = %{service | plan: plan, source: "forced"}
        RSMP.Service.publish_status(service, "plan")
        pub = %{topic: "status", changes: []}
        Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", pub)
        Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp:#{service.id}", pub)
        {service, %{status: "ok", plan: plan}}

      true ->
        msg = "Switching to plan #{plan} failed: Unknown plan"
        Logger.info("RSMP: #{msg}")
        Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp:#{service.id}", %{topic: "command_log", id: "tlc.plan.set", message: msg})
        {service, %{status: "missing", plan: plan, reason: "Plan #{plan} not found"}}
    end
  end

  def receive_command(
        service,
        %RSMP.Topic{path: %RSMP.Path{code: "plan.set"}=path},
        %{}=params,
        _properties
      ) do
    msg = "Invalid params for command #{path}: #{inspect(params)}"
    Logger.warning(msg)
    Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp:#{service.id}", %{topic: "command_log", id: "tlc.plan.set", message: msg})
    {service,nil}
  end

  def receive_command(service, topic, payload, _properties) when not is_map(payload) do
    msg = "Invalid payload for command #{topic}: #{inspect(payload)}"
    Logger.warning(msg)
    Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp:#{service.id}", %{topic: "command_log", id: "tlc", message: msg})
    {service,nil}
  end

  def receive_command(service, topic, _payload, _properties) do
    msg = "Unknown command #{topic}"
    Logger.warning(msg)
    Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp:#{service.id}", %{topic: "command_log", id: "tlc", message: msg})
    {service,nil}
  end

  def receive_reaction(service, %RSMP.Topic{path: %RSMP.Path{code: code}}, payload, _properties) do
     alarms = service.alarms
     if Map.has_key?(alarms, code) do
        alarm = alarms[code]
        alarm = RSMP.Alarm.update_from_string_map(alarm, payload)
        alarms = Map.put(alarms, code, alarm)
        service = %{service | alarms: alarms}

        RSMP.Service.publish_alarm(service, code)
        Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp:#{service.id}", %{topic: "alarm"})

        service
     else
        Logger.warning("Unknown reaction for alarm #{code}")
        service
     end
  end

  def receive_reaction(service, topic, _payload, _properties) do
    Logger.warning("Unknown reaction #{topic}")
    service
  end

  # convert from internal format to sxl format
  def format_status(service, "groups") do
    %{
      "basecyclecounter" => service.base,
      "cyclecounter" => service.cycle,
      "signalgroupstatus" => service.groups,
      "stage" => service.stage
    }
  end

  def format_status(service, "plan") do
    %{
      "status" => service.plan,
      "source" => service.source
    }
  end

  def format_status(service, "plans") do
    items =
      service.plans
      |> Map.keys()
      |> Enum.sort()
      |> Enum.join(",")

    %{"status" => items}
  end

  def format_status(service, "24") do
    items =
      service
      |> Enum.map(fn {plan, value} -> "#{plan}-#{value}" end)
      |> Enum.join(",")

    %{"status" => items}
  end

  def format_status(service, "28"), do: format_status(service, "24")
end

# ----

#  def reaction(service, %Path{code: "201"}=path, flags, _properties) do
#    path_string = to_string(path)
#    Logger.info("RSMP: Received alarm flag #{to_string(path)}, #{inspect(flags)}")
#
#    alarm = service.alarms[path_string] |> Alarm.update_from_string_map(flags)
#    service = put_in(service.alarms[path_string], alarm)
#
#    Node.publish_alarm(service, path)
#
#    pub = %{topic: "alarm", changes: %{path_string => service.alarms[path]}}
#    Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", pub)
#
#    service
#  end
#
#  def reaction(service, path, payload, _properties) do
#    Logger.warning(
#      "Unhandled reaction, path: #{inspect(path)}, payload: #{inspect(payload)}"
#    )
#
#    service
#  end
#
#  def alarm(service, _path, _flags, _properties), do: service#
