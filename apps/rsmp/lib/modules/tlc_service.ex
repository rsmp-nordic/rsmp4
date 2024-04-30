defmodule RSMP.Service.TLC do
  use RSMP.Service, name: "tlc"

  #require Logger
  #alias RSMP.{Utility, Alarm, Path}

  defstruct(
    cycle: 0,
    plan: 0
  )

  def new(options \\ []), do: __struct__(options)

  #def status(service, _path), do: service

  def action(service, args) do
    service = %{ service | plan: args}
    IO.puts "switched to plan #{service.plan}!"
    {:ok, service}
  end

#  def command(service, %Path{code: "2"}=path, plan, properties) do
#    current_plan_path = Path.new("tlc","14")
#    current_plan_path_string = Path.to_string(current_plan_path)
#    current_plan = service.statuses[current_plan_path_string][:plan]
#
#    {response, service} =
#      cond do
#        plan == current_plan ->
#          Logger.info("RSMP: Already using plan: #{plan}")
#
#          {
#            %{status: "already", plan: plan, reason: "Already using plan #{plan}"},
#            service
#          }
#
#        service.plans[plan] != nil ->
#          Logger.info("RSMP: Switching to plan: #{plan}")
#          service = put_in(service.statuses[current_plan_path_string], %{plan: plan, source: "forced"})
#          {
#            %{status: "ok", plan: plan, reason: ""},
#            service
#          }
#
#        true ->
#          Logger.info("RSMP: Unknown plan: #{plan}")
#
#          {
#            %{status: "unknown", plan: current_plan, reason: "Plan #{plan} not found"},
#            service
#          }
#      end
#
#    if properties[:response_topic] do
#      Node.publish_result(service, path, response: response, properties: properties )
#    end
#
#    if response[:status] == "ok" do
#      Node.publish_status(service, current_plan_path)
#
#      pub = %{topic: "status", changes: [path]}
#      Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", pub)
#    end
#
#    service
#  end
#
#  def command(service, path, _payload, _properties) do
#    Logger.warning(
#      "Unhandled command, path: #{Path.to_string(path)}"
#    )
#    service
#  end
#
#  def reaction(service, %Path{code: "201"}=path, flags, _properties) do
#    path_string = Path.to_string(path)
#    Logger.info("RSMP: Received alarm flag #{Path.to_string(path)}, #{inspect(flags)}")
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
#  def alarm(service, _path, _flags, _properties), do: service
end
