# RSMP Site
defmodule RSMP.Site do
  @moduledoc false
  require Logger
  alias RSMP.{Utility, Topic, Path}

  defstruct(
    id: nil,
    pid: nil,
    modules: %{},
    statuses: %{},
    alarms: %{}
  )

  # api
  def new(options \\ []), do: __struct__(options)

  def get_id(pid) do
    GenServer.call(pid, :get_id)
  end

  def get_statuses(pid) do
    GenServer.call(pid, :get_statuses)
  end

  def get_status(pid, path) do
    GenServer.call(pid, {:get_status, path})
  end

  def get_alarms(pid) do
    GenServer.call(pid, :get_alarms)
  end

  def get_alarm_flag(pid, path, flag) do
    GenServer.call(pid, {:get_alarm_flag, path, flag})
  end

  def set_status(pid, path, value) do
    GenServer.cast(pid, {:set_status, path, value})
  end

  def raise_alarm(pid, path) do
    GenServer.cast(pid, {:raise_alarm, path})
  end

  def clear_alarm(pid, path) do
    GenServer.cast(pid, {:clear_alarm, path})
  end

  def set_alarm_flag(pid, path, flag, value) do
    GenServer.cast(pid, {:set_alarm_flag, path, flag, value})
  end

  def toggle_alarm_flag(pid, path, flag) do
    GenServer.cast(pid, {:toggle_alarm_flag, path, flag})
  end

  # helpers

  def publish_status(site, path) do
    path_string = to_string(path)
    value = site.statuses[path_string]
    Logger.debug("Site: Sending status: #{path} #{Kernel.inspect(value)}")
    status = to_rsmp_status(site, path, value)
    topic = %Topic{id: site.id, type: "status", path: path}
    topic_string = to_string(topic)

    if topic_string == "" do
      Logger.warning("Site: Attempted to publish status to empty topic, path: #{path_string}")
    end

    :emqtt.publish_async(
      site.pid,
      to_string(topic),
      Utility.to_payload(status),
      [retain: true, qos: 1],
      &publish_done/1
    )
  end

  def publish_done(data) do
    Logger.debug("Site: Publish result: #{Kernel.inspect(data)}")
  end

  def alarm_flag_string(site, path) do
    site.alarms[to_string(path)]
    |> Map.from_struct()
    |> Enum.filter(fn {_flag, value} -> value == true end)
    |> Enum.map(fn {flag, _value} -> flag end)
    |> inspect()
  end

  def publish_alarm(site, path) do
    flags = alarm_flag_string(site, path)
    path_string = to_string(path)
    Logger.debug("Site: Sending alarm: #{path_string} #{flags}")

    topic = %Topic{id: site.id, type: "alarm", path: path}
    topic_string = to_string(topic)

    if topic_string == "" do
      Logger.warning("Site: Attempted to publish alarm to empty topic, path: #{path_string}")
    end

    :emqtt.publish_async(
      site.pid,
      topic_string,
      Utility.to_payload(Map.from_struct(site.alarms[path_string])),
      [retain: true, qos: 1],
      &publish_done/1
    )
  end

  def publish_all(site) do
    for path <- Map.keys(site.alarms), do: publish_alarm(site, Path.from_string(path))
    for path <- Map.keys(site.statuses), do: publish_status(site, Path.from_string(path))
  end

  def publish_state(site, state) do
    topic_string = "#{site.id}/presence"

    if topic_string == "" do
      Logger.warning("Site: Attempted to publish presence to empty topic")
    end

    :emqtt.publish_async(
      site.pid,
      topic_string,
      Utility.to_payload(state),
      [retain: true, qos: 1],
      &publish_done/1
    )
  end

  def subscribe_to_topics(%{pid: pid, id: id}) do
    # subscribe to commands
    {:ok, _, _} = :emqtt.subscribe(pid, {"#{id}/command/#", 1})

    # subscribe to channel throttling
    {:ok, _, _} = :emqtt.subscribe(pid, {"#{id}/throttle/#", 1})
  end

  def handle_throttle(site, topic, data) do
    channel_name = topic.channel_name

    action = if is_map(data), do: data["action"], else: nil

    cond do
      action not in ["start", "stop"] ->
        Logger.warning("Site: Invalid throttle action for #{topic.path}: #{inspect(data)}")
        site

      true ->
        case RSMP.Registry.lookup_channel(site.id, topic.path.code, channel_name) do
          [{pid, _}] ->
            case action do
              "start" -> RSMP.Channel.start_channel(pid)
              "stop" -> RSMP.Channel.stop_channel(pid)
            end

            channel_segment = channel_name || "default"
            channel_key = "#{topic.path.code}/#{channel_segment}"
            pub = %{topic: "channel", channel: channel_key, state: if(action == "start", do: "running", else: "stopped")}
            Phoenix.PubSub.broadcast(RSMP.PubSub, "site:#{site.id}", pub)

          [] ->
            Logger.warning("Site: Channel not found for throttle: #{topic.path}")
        end

        site
    end
  end

  def handle_publish(topic, _module, data, site) do
    Logger.warning("Site: Unhandled publish, topic: #{inspect(topic)}, data: #{inspect(data)}")
    {:noreply, site}
  end

  def handle_status(topic, publish, site) do
    Logger.warning(
      "Site: Unhandled status, topic: #{inspect(topic)}, publish: #{inspect(publish)}"
    )

    {:noreply, site}
  end

  def module(site, code), do: site.modules |> Map.fetch!(code)
  def converter(site, code), do: module(site, code).converter

  def from_rsmp_status(site, path, data) do
    converter(site, path.code).from_rsmp_status(path.code, data)
  end

  def to_rsmp_status(site, path, data) do
    converter(site, path.code).to_rsmp_status(path.code, data)
  end
end
