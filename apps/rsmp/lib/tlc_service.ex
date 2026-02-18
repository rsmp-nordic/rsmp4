defmodule RSMP.Service.TLC do
  use RSMP.Service, name: "tlc"
  require Logger

  @impl true
  def status_codes(), do: ["groups", "plan", "plans"]

  @impl true
  def alarm_codes(), do: ["hardware.error", "hardware.warning"]

  # Signal group state transitions: green -> yellow -> red -> red+yellow -> green
  @sg_transitions %{
    "G" => "Y",
    "Y" => "r",
    "r" => "u",
    "u" => "G"
  }

  @tick_interval_ms 1_000
  @group_transition_every_ticks 3

  defstruct(
    id: nil,
    cycle: 0,
    groups: %{},
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
  def new(id, data \\ %{}) do
     alarms =
       for code <- alarm_codes(), into: %{} do
         {code, RSMP.Alarm.new()}
       end

     groups =
       data
       |> Map.get(:groups, %{})
       |> normalize_groups()

     service = __struct__(Map.merge(data, %{id: id, alarms: alarms, groups: groups}))

    # Start the signal group simulation timer
    Process.send_after(self(), :tick_groups, @tick_interval_ms)

     service
  end

  @impl GenServer
  def handle_info(:tick_groups, service) do
    # Advance cycle counters every second
    cycle = service.cycle + 1

    # Transition signal groups less frequently than cycle counter updates
    groups_changed = rem(cycle, @group_transition_every_ticks) == 0

    {groups, stage, changed_groups} =
      if groups_changed do
        {group_id, current_state} = next_group_to_transition(service.groups, cycle)
        next_state = Map.get(@sg_transitions, current_state, "r")
        groups = Map.put(service.groups, group_id, next_state)
        changed_groups = %{group_id => next_state}

        stage =
          if group_id == "1" and next_state == "G",
            do: rem(service.stage + 1, 4),
            else: service.stage

        {groups, stage, changed_groups}
      else
        {service.groups, service.stage, %{}}
      end

    service = %{service | cycle: cycle, groups: groups, stage: stage}

    if groups_changed do
      # signalgroupstatus/stage are the on_change triggers for tlc.groups stream
      values =
        %{
          "signalgroupstatus" => changed_groups,
          "cyclecounter" => cycle
        }
        |> maybe_put_stage(service.stage, stage)

      RSMP.Service.report_to_streams(service.id, "tlc", "groups", values)
    end

    # Notify local Site LiveView without signaling supervisor status updates
    Phoenix.PubSub.broadcast(RSMP.PubSub, "site:#{service.id}", %{topic: "local_status"})

    # Schedule next tick
    Process.send_after(self(), :tick_groups, @tick_interval_ms)

    {:noreply, service}
  end

  @impl GenServer
  def handle_call({:set_plan_local, plan}, _from, service) do
    {service, _result} = apply_plan_set(service, plan, :local)
    {:reply, :ok, service}
  end

  def apply_plan_set(service, plan, origin \\ :supervisor) do
    cond do
      plan == service.plan ->
        msg = "Plan #{plan} already used"
        Logger.info("RSMP: #{msg}")

        Phoenix.PubSub.broadcast(RSMP.PubSub, "site:#{service.id}", %{
          topic: "command_log",
          id: "tlc.plan.set",
          message: msg
        })

        if origin == :local do
          Phoenix.PubSub.broadcast(RSMP.PubSub, "site:#{service.id}", %{
            topic: "plan_result",
            result: %{message: "Already using plan #{plan}"}
          })
        end

        {service, %{status: "already", plan: plan, reason: "Already using plan #{plan}"}}

      service.plans[plan] != nil ->
        msg = "Switching to plan #{plan}"
        Logger.info("RSMP: #{msg}")

        Phoenix.PubSub.broadcast(RSMP.PubSub, "site:#{service.id}", %{
          topic: "command_log",
          id: "tlc.plan.set",
          message: msg
        })

        service = %{service | plan: plan, source: "forced"}
        RSMP.Service.report_to_streams(service, "plan")
        Phoenix.PubSub.broadcast(RSMP.PubSub, "site:#{service.id}", %{topic: "local_status"})

        message =
          case origin do
            :supervisor -> "Supervisor switched to plan #{plan}"
            :local -> "Switched to plan #{plan}"
          end

        Phoenix.PubSub.broadcast(RSMP.PubSub, "site:#{service.id}", %{
          topic: "plan_result",
          result: %{message: message}
        })

        {service, %{status: "ok", plan: plan}}

      true ->
        msg = "Switching to plan #{plan} failed: Unknown plan"
        Logger.info("RSMP: #{msg}")

        Phoenix.PubSub.broadcast(RSMP.PubSub, "site:#{service.id}", %{
          topic: "command_log",
          id: "tlc.plan.set",
          message: msg
        })

        if origin == :local do
          Phoenix.PubSub.broadcast(RSMP.PubSub, "site:#{service.id}", %{
            topic: "plan_result",
            result: %{message: "Local switch failed: plan #{plan} not found"}
          })
        end

        {service, %{status: "missing", plan: plan, reason: "Plan #{plan} not found"}}
    end
  end

  defp maybe_put_stage(values, previous_stage, current_stage) do
    if previous_stage != current_stage do
      Map.put(values, "stage", current_stage)
    else
      values
    end
  end

  defp next_group_to_transition(groups, cycle) do
    group_ids =
      groups
      |> Map.keys()
      |> Enum.sort_by(&group_sort_key/1)

    if group_ids == [] do
      {"1", "r"}
    else
      tick = div(cycle, @group_transition_every_ticks) - 1
      group_id = Enum.at(group_ids, rem(tick, length(group_ids)))
      {group_id, Map.get(groups, group_id, "r")}
    end
  end

  defp group_sort_key(key) when is_binary(key) do
    case Integer.parse(key) do
      {number, ""} -> {0, number}
      _ -> {1, key}
    end
  end

  defp group_sort_key(key), do: {2, key}

  defp normalize_groups(groups) when is_map(groups) do
    groups
    |> Enum.into(%{}, fn {key, state} -> {to_string(key), state} end)
  end

  defp normalize_groups(groups) when is_binary(groups) do
    groups
    |> String.graphemes()
    |> Enum.with_index(1)
    |> Enum.into(%{}, fn {state, index} -> {Integer.to_string(index), state} end)
  end

  defp normalize_groups(_groups), do: %{}
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
    RSMP.Service.TLC.apply_plan_set(service, plan, :supervisor)
  end

  def receive_command(
        service,
        %RSMP.Topic{path: %RSMP.Path{code: "plan.set"}=path},
        %{}=params,
        _properties
      ) do
    msg = "Invalid params for command #{path}: #{inspect(params)}"
    Logger.warning(msg)
    Phoenix.PubSub.broadcast(RSMP.PubSub, "site:#{service.id}", %{topic: "command_log", id: "tlc.plan.set", message: msg})
    {service,nil}
  end

  def receive_command(service, topic, payload, _properties) when not is_map(payload) do
    msg = "Invalid payload for command #{topic}: #{inspect(payload)}"
    Logger.warning(msg)
    Phoenix.PubSub.broadcast(RSMP.PubSub, "site:#{service.id}", %{topic: "command_log", id: "tlc", message: msg})
    {service,nil}
  end

  def receive_command(service, topic, _payload, _properties) do
    msg = "Unknown command #{topic}"
    Logger.warning(msg)
    Phoenix.PubSub.broadcast(RSMP.PubSub, "site:#{service.id}", %{topic: "command_log", id: "tlc", message: msg})
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
        Phoenix.PubSub.broadcast(RSMP.PubSub, "site:#{service.id}", %{topic: "alarm"})

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
