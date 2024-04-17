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

  def status(node, _path), do: node

  def command(_node, %Path{code: "2"}=path, plan, properties) do
    current_plan_path = Path.new("tlc","14")
    current_plan_path_string = Path.to_string(current_plan_path)
    current_plan = service.statuses[current_plan_path_string][:plan]

    {response, node} =
      cond do
        plan == current_plan ->
          Logger.info("RSMP: Already using plan: #{plan}")

          {
            %{status: "already", plan: plan, reason: "Already using plan #{plan}"},
            node
          }

        service.plans[plan] != nil ->
          Logger.info("RSMP: Switching to plan: #{plan}")
          node = put_in(node.service.statuses[current_plan_path_string], %{plan: plan, source: "forced"})
          {
            %{status: "ok", plan: plan, reason: ""},
            node
          }

        true ->
          Logger.info("RSMP: Unknown plan: #{plan}")

          {
            %{status: "unknown", plan: current_plan, reason: "Plan #{plan} not found"},
            node
          }
      end

    if properties[:response_topic] do
      Node.publish_result(node, path, response: response, properties: properties )
    end

    if response[:status] == "ok" do
      Node.publish_status(node, current_plan_path)

      pub = %{topic: "status", changes: [path]}
      Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", pub)
    end

    node
  end

  def command(node, path, _payload, _properties) do
    Logger.warning(
      "Unhandled command, path: #{Path.to_string(path)}"
    )
    node
  end

  def reaction(node, %Path{code: "201"}=path, flags, _properties) do
    path_string = Path.to_string(path)
    Logger.info("RSMP: Received alarm flag #{Path.to_string(path)}, #{inspect(flags)}")

    alarm = service.alarms[path_string] |> Alarm.update_from_string_map(flags)
    service = put_in(service.alarms[path_string], alarm)

    Node.publish_alarm(node, path)

    pub = %{topic: "alarm", changes: %{path_string => service.alarms[path]}}
    Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", pub)

    node
  end

  def reaction(node, path, payload, _properties) do
    Logger.warning(
      "Unhandled reaction, path: #{inspect(path)}, payload: #{inspect(payload)}"
    )

    node
  end

  def alarm(node, _path, _flags, _properties), do: node
end
