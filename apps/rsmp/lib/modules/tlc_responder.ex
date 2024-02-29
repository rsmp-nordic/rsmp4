defmodule RSMP.Responder.TLC do
  @behaviour RSMP.Responder
  require Logger
  alias RSMP.{Utility, Site, Alarm, Path}

  def receive_command(site, %Path{code: "2"}=path, plan, properties) do
    current_plan = site.statuses["tlc/14"]["status"]
    status_path = Path.to_string(path)

    {response, site} =
      cond do
        plan == current_plan ->
          Logger.info("RSMP: Already using plan: #{plan}")

          {
            %{status: "already", plan: plan, reason: "Already using plan #{plan}"},
            site
          }

        site.plans[plan] != nil ->
          Logger.info("RSMP: Switching to plan: #{plan}")

          site =
            site |> put_in([:statuses, status_path], %{"status" => plan, "source" => "forced"})

          {
            %{status: "ok", plan: plan, reason: ""},
            site
          }

        true ->
          Logger.info("RSMP: Unknown plan: #{plan}")

          {
            %{status: "unknown", plan: plan, reason: "Plan #{plan} not found"},
            site
          }
      end

    if properties[:response_topic] do
      # site, Topic, Properties, Payload, Opts, Timeout, Callback
      :emqtt.publish_async(
        site.pid,
        properties[:response_topic],
        %{ "Correlation-Data": properties[:command_id] },
        Utility.to_payload(response),
        [retain: true, qos: 1],
        :infinity,
        &Site.publish_done/1
      )
    end

    if response[:status] == "ok" do
      RSMP.Site.publish_status(site, status_path)

      pub = %{topic: "status", changes: [status_path]}
      Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", pub)
    end

    site
  end

  def receive_command(site, path, _data, _properties) do
    Logger.warning(
      "Unhandled command, path: #{Path.to_string(path)}"
    )

    site
  end

  def receive_reaction(site, %Path{code: "201"}=path, flags, _properties) do
    path_string = Path.to_string(path)
    Logger.info("RSMP: Received alarm flag #{Path.to_string(path)}, #{inspect(flags)}")

    alarm = site.alarms[path_string] |> Alarm.update_from_string_map(flags)
    site = put_in(site.alarms[path_string], alarm)

    Site.publish_alarm(site, path)

    pub = %{topic: "alarm", changes: %{path_string => site.alarms[path]}}
    Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", pub)

    site
  end

  def receive_reaction(site, code, component, data) do
    Logger.warning(
      "Unhandled reaction, code: #{inspect(code)}, component: #{inspect(component)}, publish: #{inspect(data)}"
    )

    site
  end

  def receive_alarm(site, _path, _flags, _properties) do
    site
  end
end
