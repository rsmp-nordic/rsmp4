defmodule RSMP.Responder.TLC do
  @behaviour RSMP.Responder
  require Logger
  alias RSMP.{Utility,Site,Alarm}

  def converter(), do: RSMP.Converter.TLC
  
  def receive_command(client, "2", component, %{payload: payload, properties: properties}) do
    options = %{
      component: component,
      plan: Utility.from_payload(payload),
      response_topic: properties[:"Response-Topic"],
      command_id: properties[:"Correlation-Data"]
    }

    set_plan(client, options)
  end

  def receive_command(client, code, component, data) do
    Logger.warning(
      "Unhandled command, code: #{inspect(code)}, component: #{inspect(component)}, publish: #{inspect(data)}"
    )
    client
  end

  def receive_reaction(client, "201"=code, component, %{payload: payload}) do
    flags = Utility.from_payload(payload)
    path = Utility.build_path("tlc", code, component)

    Logger.info("RSMP: Received alarm flag #{path}, #{inspect(flags)}")

    alarm = client.alarms[path] |> Alarm.update_from_string_map(flags)
    client = put_in(client.alarms[path], alarm)

    Site.publish_alarm(client, path)

    data = %{topic: "alarm", changes: %{path => client.alarms[path]}}
    Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", data)

    client
  end

  def receive_reaction(client, code, component, data) do
    Logger.warning(
      "Unhandled reaction, code: #{inspect(code)}, component: #{inspect(component)}, publish: #{inspect(data)}"
    )
    client
  end

  def set_plan(client, %{
        component: _component,
        plan: plan,
        response_topic: response_topic,
        command_id: command_id
      }) do
    current_plan = client.statuses["tlc/14"]["status"]
    status_path = "tlc/14"

    {response, client} =
      cond do
        plan == current_plan ->
          Logger.info("RSMP: Already using plan: #{plan}")

          {
            %{status: "already", plan: plan, reason: "Already using plan #{plan}"},
            client
          }

        client.plans[plan] != nil ->
          Logger.info("RSMP: Switching to plan: #{plan}")

          client =
            client |> put_in([:statuses, status_path], %{"status" => plan, "source" => "forced"})

          {
            %{status: "ok", plan: plan, reason: ""},
            client
          }

        true ->
          Logger.info("RSMP: Unknown plan: #{plan}")

          {
            %{status: "unknown", plan: plan, reason: "Plan #{plan} not found"},
            client
          }
      end

    if response_topic do
      properties = %{
        "Correlation-Data": command_id
      }

      # Client, Topic, Properties, Payload, Opts, Timeout, Callback
      :emqtt.publish_async(
        client.pid,
        response_topic,
        properties,
        Utility.to_payload(response),
        [retain: true, qos: 1],
        :infinity,
        &Site.publish_done/1
      )
    end

    if response[:status] == "ok" do
      RSMP.Site.publish_status(client, status_path)

      data = %{topic: "status", changes: [status_path]}
      Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", data)
    end

    client
  end
end
