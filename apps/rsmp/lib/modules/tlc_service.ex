defmodule RSMP.Service.TLC do
  defstruct(
    cycle: 0,
    plan: 0
  )

  def name(), do: "tlc"
end

defimpl RSMP.Service.Protocol, for: RSMP.Service.TLC do
  require Logger
  alias RSMP.{Utility, Service, Alarm, Path}

  def status(_service, _node, _path) do
    nil
  end


  def command(service, _node, %Path{code: "2"}=path, plan, properties) do
    current_plan_path = Path.new("tlc","14")
    current_plan_path_string = Path.to_string(current_plan_path)
    current_plan = service.statuses[current_plan_path_string][:plan]

    {response, service} =
      cond do
        plan == current_plan ->
          Logger.info("RSMP: Already using plan: #{plan}")

          {
            %{status: "already", plan: plan, reason: "Already using plan #{plan}"},
            service
          }

        service.plans[plan] != nil ->
          Logger.info("RSMP: Switching to plan: #{plan}")
          service = put_in(service.statuses[current_plan_path_string], %{plan: plan, source: "forced"})
          {
            %{status: "ok", plan: plan, reason: ""},
            service
          }

        true ->
          Logger.info("RSMP: Unknown plan: #{plan}")

          {
            %{status: "unknown", plan: current_plan, reason: "Plan #{plan} not found"},
            service
          }
      end

    if properties[:response_topic] do
      Logger.info("RSMP: Sending result: #{Path.to_string(path)}, #{inspect(response)}")
      # service, Topic, Properties, Payload, Opts, Timeout, Callback
      :emqtt.publish_async(
        service.pid,
        properties[:response_topic],
        %{ "Correlation-Data": properties[:command_id] },
        Utility.to_payload(response),
        [retain: true, qos: 1],
        :infinity,
        &Service.publish_done/1
      )
    end

    if response[:status] == "ok" do
      RSMP.Service.publish_status(service, current_plan_path)

      pub = %{topic: "status", changes: [path]}
      Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", pub)
    end

    service
  end

  def command(service, _node, path, _payload, _properties) do
    Logger.warning(
      "Unhandled command, path: #{Path.to_string(path)}"
    )

    service
  end

  def reaction(service, node, %Path{code: "201"}=path, flags, _properties) do
    path_string = Path.to_string(path)
    Logger.info("RSMP: Received alarm flag #{Path.to_string(path)}, #{inspect(flags)}")

    alarm = service.alarms[path_string] |> Alarm.update_from_string_map(flags)
    service = put_in(service.alarms[path_string], alarm)

    Node.publish_alarm(service, node, path)

    pub = %{topic: "alarm", changes: %{path_string => service.alarms[path]}}
    Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", pub)

    service
  end

  def reaction(service, _node, path, payload, _properties) do
    Logger.warning(
      "Unhandled reaction, path: #{inspect(path)}, payload: #{inspect(payload)}"
    )

    service
  end

  def alarm(service, _node, _path, _flags, _properties) do
    service
  end
end
