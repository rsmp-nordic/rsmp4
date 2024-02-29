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
    path_string = Path.to_string(path)
    value = site.statuses[path_string]
    Logger.info("RSMP: Sending status: #{path_string} #{Kernel.inspect(value)}")
    status = to_rsmp_status(site, path, value)
    topic = %Topic{id: site.id, type: "status", path: path}

    :emqtt.publish_async(
      site.pid,
      Topic.to_string(topic),
      Utility.to_payload(status),
      [retain: true, qos: 1],
      &publish_done/1
    )
  end

  def publish_done(data) do
    Logger.debug("RSMP: Publish result: #{Kernel.inspect(data)}")
  end

  def alarm_flag_string(site, path) do
    site.alarms[path]
    |> Map.from_struct()
    |> Enum.filter(fn {_flag, value} -> value == true end)
    |> Enum.map(fn {flag, _value} -> flag end)
    |> inspect()
  end

  def publish_alarm(site, path) do
    flags = alarm_flag_string(site, path)
    Logger.info("RSMP: Sending alarm: #{path} #{flags}")

    :emqtt.publish_async(
      site.pid,
      "#{site.id}/alarm/#{path}",
      Utility.to_payload(site.alarms[path]),
      [retain: true, qos: 1],
      &publish_done/1
    )
  end

  def publish_all(site) do
    for path <- Map.keys(site.alarms), do: publish_alarm(site, path)
    # for path <- Map.keys(site.statuses), do: publish_status(site, path)
  end

  def publish_state(site, state) do
    :emqtt.publish_async(
      site.pid,
      "#{site.id}/state",
      Utility.to_payload(state),
      [retain: true, qos: 1],
      &publish_done/1
    )
  end

  def subscribe_to_topics(%{pid: pid, id: id}) do
    # subscribe to commands
    {:ok, _, _} = :emqtt.subscribe(pid, {"#{id}/command/#", 1})

    # subscribe to alarm reactions
    {:ok, _, _} = :emqtt.subscribe(pid, {"#{id}/reaction/#", 1})
  end

  def handle_publish(topic, _module, data, site) do
    Logger.warning("Unhandled publish, topic: #{inspect(topic)}, data: #{inspect(data)}")
    {:noreply, site}
  end

  def handle_status(topic, component, publish, site) do
    Logger.warning(
      "Unhandled status, topic: #{inspect(topic)}, component: #{inspect(component)}, publish: #{inspect(publish)}"
    )

    {:noreply, site}
  end

  def module(site, name), do: site.modules |> Map.fetch!(name)
  def responder(site, name), do: module(site, name).responder
  def converter(site, name), do: module(site, name).converter

  def from_rsmp_status(site, path, data) do
    converter(site, path.module).from_rsmp_status(path.code, data)
  end

  def to_rsmp_status(site, path, data) do
    converter(site, path.module).to_rsmp_status(path.code, data)
  end

  # Enable "use RSMP.Site" in your RSMP Site modules
  defmacro __using__(_options) do
    quote do
      use GenServer
      require Logger
      alias RSMP.{Utility, Site, Alarm, Time, Topic, Path}

      # api
      def start_link(_options \\ []) do
        {:ok, pid} = GenServer.start_link(__MODULE__, [])
        Logger.info("RSMP: Starting site with pid #{inspect(pid)}")
        {:ok, pid}
      end

      # genserver
      @impl true
      def init([]) do
        Logger.info("RSMP: starting emqtt")

        id = site_id()

        site =
          %RSMP.Site{
            id: id,
            modules: module_mapping()
          }
          |> setup()

        options =
          Utility.client_options()
          |> Map.merge(%{
            name: String.to_atom(id),
            clientid: id,
            will_topic: "#{id}/state",
            will_payload: Utility.to_payload(0),
            will_retain: true
          })

        {:ok, pid} = :emqtt.start_link(options)
        {:ok, _} = :emqtt.connect(pid)
        site = Map.put(site, :pid, pid)
        {:ok, site, {:continue, :start_emqtt}}
      end

      @impl true
      def handle_continue(:start_emqtt, %{pid: pid, id: _} = site) do
        Site.subscribe_to_topics(site)
        Site.publish_state(site, 1)
        Site.publish_all(site)
        continue_client()
        {:noreply, site}
      end

      # genserver api imlementation
      @impl true
      def handle_call(:get_id, _from, site) do
        {:reply, site.id, site}
      end

      @impl true
      def handle_call(:get_statuses, _from, site) do
        {:reply, site.statuses, site}
      end

      @impl true
      def handle_call({:get_status, path}, _from, site) do
        {:reply, site.statuses[path], site}
      end

      @impl true
      def handle_call(:get_alarms, _from, site) do
        {:reply, site.alarms, site}
      end

      @impl true
      def handle_call({:get_alarm_flag, path, flag}, _from, site) do
        alarm = site.alarms[path] || Alarm.new()
        flag = Alarm.get_flag(alarm, flag)
        {:reply, flag, site}
      end

      @impl true
      def handle_cast({:set_status, path, value}, site) do
        site = %{site | statuses: Map.put(site.statuses, path, value)}
        Site.publish_status(site, path)

        data = %{topic: "status", changes: [path]}
        Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", data)
        {:noreply, site}
      end

      @impl true
      def handle_cast({:raise_alarm, path}, site) do
        if Alarm.active?(site.alarms[path]) == false do
          site = Alarm.flag_on(site.alarms[path], :active)
          Site.publish_alarm(site, path)

          data = %{topic: "alarm", changes: [path]}
          Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", data)
          {:noreply, site}
        else
          {:noreply, site}
        end
      end

      @impl true
      def handle_cast({:clear_alarm, path}, site) do
        if Alarm.active?(site.alarms[path]) do
          site = Alarm.flag_off(site.alarms[path], :active)
          Site.publish_alarm(site, path)

          data = %{topic: "alarm", changes: [path]}
          Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", data)
          {:noreply, site}
        else
          {:noreply, site}
        end
      end

      @impl true
      def handle_cast({:set_alarm_flag, path, flag, value}, site) do
        if Alarm.get_flag(site.alarms[path], flag) != value do
          site = Alarm.set_flag(site.alarms[path], flag, value)
          Site.publish_alarm(site, path)

          data = %{topic: "alarm", changes: [path]}
          Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", data)
          {:noreply, site}
        else
          {:noreply, site}
        end
      end

      @impl true
      def handle_cast({:toggle_alarm_flag, path, flag}, site) do
        alarm = site.alarms[path] |> Alarm.toggle_flag(flag)
        site = put_in(site.alarms[path], alarm)
        Site.publish_alarm(site, path)

        data = %{topic: "alarm", changes: [path]}
        Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", data)

        {:noreply, site}
      end

      # mqtt
      @impl true
      def handle_info({:publish, publish}, site) do
        topic = Topic.from_string(publish.topic)
        responder = Site.responder(site, topic.path.module)
        data = Utility.from_payload(publish[:payload])
        site =
          case topic.type do
            "status" -> responder.receive_status(site, topic.code, topic.component, data)
            "command" ->
              properties = %{
                response_topic: publish[:properties][:"Response-Topic"],
                command_id: publish[:properties][:"Correlation-Data"]
              }
              responder.receive_command(site, topic.code, topic.component, data, properties)
            "reaction" -> responder.receive_reaction(site, topic.code, topic.component, data)
          end

        {:noreply, site}
      end

      @impl true
      def handle_info({:connected, _publish}, site) do
        Logger.info("RSMP: Connected")
        Site.subscribe_to_topics(site)
        {:noreply, site}
      end

      @impl true
      def handle_info({:disconnected, _publish}, site) do
        Logger.warning("RSMP: Disconnected")
        {:noreply, site}
      end

      # helpers
      def module_mapping() do
        for module <- modules(), into: %{}, do: {module.name, module}
      end
    end
  end
end
