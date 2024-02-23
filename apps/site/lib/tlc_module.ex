defmodule RSMP.Site.Module.TLC do
  @behaviour RSMP.Site.Module
  require Logger
  alias RSMP.Utility
  alias RSMP.Site

  def receive_command(tlc, 2, component, %{payload: payload, properties: properties}) do
    options = %{
      component: component,
      plan: Utility.from_payload(payload),
      response_topic: properties[:"Response-Topic"],
      command_id: properties[:"Correlation-Data"]
    }

    set_plan(tlc, options)
  end

  def receive_command(tlc, code, component, data) do
    Logger.warning(
      "Unhandled command, code: #{inspect(code)}, component: #{inspect(component)}, publish: #{inspect(data)}"
    )

    tlc
  end

  # def send_result(site, code, data) do
  # def send_status(site, code, data) do
  # def send_alarm(site, code, data) do

#  def receive_reaction(tlc, 2, component, %{payload: payload}) do
#    flags = from_payload(payload)
#    path = build_path(module, code, component)
#
#    Logger.info("RSMP: Received alarm flag #{path}, #{inspect(flags)}")
#
#    alarm = client.alarms[path] |> Alarm.update_from_string_map(flags)
#    client = put_in(client.alarms[path], alarm)
#
#    Logger.info(inspect(alarm))
#    Site.publish_alarm(client, path)
#
#    data = %{topic: "alarm", changes: %{path => client.alarms[path]}}
#    Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", data)
#
#    {:noreply, client}
#  end

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


 # export status from internal format to sxl format

  def to_rsmp_status(1, data) do
    %{
      "basecyclecounter" => data.base,
      "cyclecounter" => data.cycle,
      "signalgroupstatus" => data.groups,
      "stage" => data.stage
    }
  end

  def to_rsmp_status(14, data) do
    %{
      "status" => data.plan,
      "source" => data.source
    }
  end

  def to_rsmp_status(22, data) do
    items =
      data
      |> Enum.join(",")

    %{"status" => items}
  end

  def to_rsmp_status(24, data) do
    items =
      data
      |> Enum.map(fn {plan, value} -> "#{plan}-#{value}" end)
      |> Enum.join(",")

    %{"status" => items}
  end

  def to_rsmp_status(28, data) do
    items =
      data
      |> Enum.map(fn {plan, value} -> "#{plan}-#{value}" end)
      |> Enum.join(",")

    %{"status" => items}
  end


  # import status from sxl format to internal format

  def from_rsmp_status(1, data) do
    %{
      base: data["basecyclecounter"],
      cycle: data["cyclecounter"],
      groups: data["signalgroupstatus"],
      stage: data["stage"]
    }
  end

  def from_rsmp_status(14, data) do
    %{
      plan: data["status"],
      source: data["source"]
    }
  end

  def from_rsmp_status(24, data) do
    items = String.split(data["status"], ",")

    for item <- items, into: %{} do
      [plan, value] = String.split(item, "-")
      {String.to_integer(plan), String.to_integer(value)}
    end
  end

  def from_rsmp_status(28, component, data), do: from_rsmp_status(24, component, data)
end
