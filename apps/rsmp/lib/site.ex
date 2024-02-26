# RSMP Site
defmodule RSMP.Site do
  @moduledoc false
  require Logger
  alias RSMP.Utility

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

  def publish_status(client, path) do
    value = client.statuses[path]
    Logger.info("RSMP: Sending status: #{path} #{Kernel.inspect(value)}")

    module = Utility.find_module(client,module)
    status = module.converter.to_rsmp_status(client, path, value)

    :emqtt.publish_async(
      client.pid,
      "#{client.id}/status/#{path}",
      Utility.to_payload(status),
      [retain: true, qos: 1],
      &publish_done/1
    )
  end

  def publish_done(data) do
    Logger.debug("RSMP: Publish result: #{Kernel.inspect(data)}")
  end

  def alarm_flag_string(client, path) do
    client.alarms[path]
    |> Map.from_struct()
    |> Enum.filter(fn {_flag, value} -> value == true end)
    |> Enum.map(fn {flag, _value} -> flag end)
    |> inspect()
  end

  def publish_alarm(client, path) do
    flags = alarm_flag_string(client, path)
    Logger.info("RSMP: Sending alarm: #{path} #{flags}")

    :emqtt.publish_async(
      client.pid,
      "#{client.id}/alarm/#{path}",
      RSMP.Utility.to_payload(client.alarms[path]),
      [retain: true, qos: 1],
      &publish_done/1
    )
  end

  def publish_all(client) do
    for path <- Map.keys(client.alarms), do: publish_alarm(client, path)
    for path <- Map.keys(client.statuses), do: publish_status(client, path)
  end

  def publish_state(client, state) do
    :emqtt.publish_async(
      client.pid,
      "#{client.id}/state",
      RSMP.Utility.to_payload(state),
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

  def handle_publish({_id, "reaction", module, code}, component, data, client) do
    client = Utility.find_module(client,module).receive_reaction(client, code, component, data)
    {:noreply, client}
  end

  def handle_publish({_id_, "status", module, code}, component, data, client) do
    client = Utility.find_module(client,module).receive_status(client, code, component, data)
    {:noreply, client}
  end

  def handle_publish({_id, "command", module, code}, component, data, client) do
    client = Utility.find_module(client,module).receive_command(client, code, component, data)
    {:noreply, client}
  end

  def handle_publish(topic, component, data, client) do
    Logger.warning(
      "Unhandled publish, topic: #{inspect(topic)}, component: #{inspect(component)}, data: #{inspect(data)}"
    )
    {:noreply, client}
  end

  def handle_status(topic, component, publish, client) do
    Logger.warning(
      "Unhandled status, topic: #{inspect(topic)}, component: #{inspect(component)}, publish: #{inspect(publish)}"
    )

    {:noreply, client}
  end


  # Enable "use RSMP.Site" in your RSMP Site modules
  defmacro __using__(_options) do
    quote do
      use GenServer
      require Logger
      alias RSMP.Site
      import RSMP.Utility
      alias RSMP.Alarm

      # api
      def start_link(_options \\ []) do
        {:ok, pid} = GenServer.start_link(__MODULE__, [])
        Logger.info("RSMP: Starting client with pid #{inspect(pid)}")
        {:ok, pid}
      end

      # genserver
      @impl true
      def init([]) do
        Logger.info("RSMP: starting emqtt")

        id = client_id()
        client = init_client(%{id: id})

        options =
          client_options()
          |> Map.merge(%{
            name: String.to_atom(id),
            clientid: id,
            will_topic: "#{id}/state",
            will_payload: to_payload(0),
            will_retain: true
          })

        {:ok, pid} = :emqtt.start_link(options)
        {:ok, _} = :emqtt.connect(pid)
        client = Map.put(client, :pid, pid)
        {:ok, client, {:continue, :start_emqtt}}
      end

      @impl true
      def handle_continue(:start_emqtt, %{pid: pid, id: _} = client) do
        RSMP.Site.subscribe_to_topics(client)
        Site.publish_state(client, 1)
        Site.publish_all(client)
        continue_client()
        {:noreply, client}
      end

      # genserver api imlementation
      @impl true
      def handle_call(:get_id, _from, client) do
        {:reply, client.id, client}
      end

      @impl true
      def handle_call(:get_statuses, _from, client) do
        {:reply, client.statuses, client}
      end

      @impl true
      def handle_call({:get_status, path}, _from, client) do
        {:reply, client.statuses[path], client}
      end

      @impl true
      def handle_call(:get_alarms, _from, client) do
        {:reply, client.alarms, client}
      end

      @impl true
      def handle_call({:get_alarm_flag, path, flag}, _from, client) do
        alarm = client.alarms[path] || Alarm.new()
        flag = Alarm.get_flag(alarm, flag)
        {:reply, flag, client}
      end

      @impl true
      def handle_cast({:set_status, path, value}, client) do
        client = %{client | statuses: Map.put(client.statuses, path, value)}
        Site.publish_status(client, path)

        data = %{topic: "status", changes: [path]}
        Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", data)
        {:noreply, client}
      end

      @impl true
      def handle_cast({:raise_alarm, path}, client) do
        if Alarm.active?(client.alarms[path]) == false do
          client = Alarm.flag_on(client.alarms[path], :active)
          Site.publish_alarm(client, path)

          data = %{topic: "alarm", changes: [path]}
          Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", data)
          {:noreply, client}
        else
          {:noreply, client}
        end
      end

      @impl true
      def handle_cast({:clear_alarm, path}, client) do
        if Alarm.active?(client.alarms[path]) do
          client = Alarm.flag_off(client.alarms[path], :active)
          Site.publish_alarm(client, path)

          data = %{topic: "alarm", changes: [path]}
          Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", data)
          {:noreply, client}
        else
          {:noreply, client}
        end
      end

      @impl true
      def handle_cast({:set_alarm_flag, path, flag, value}, client) do
        if Alarm.get_flag(client.alarms[path], flag) != value do
          client = Alarm.set_flag(client.alarms[path], flag, value)
          Site.publish_alarm(client, path)

          data = %{topic: "alarm", changes: [path]}
          Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", data)
          {:noreply, client}
        else
          {:noreply, client}
        end
      end

      @impl true
      def handle_cast({:toggle_alarm_flag, path, flag}, client) do
        alarm = client.alarms[path] |> Alarm.toggle_flag(flag)
        client = put_in(client.alarms[path], alarm)
        Site.publish_alarm(client, path)

        data = %{topic: "alarm", changes: [path]}
        Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", data)

        {:noreply, client}
      end

      # mqtt
      @impl true
      def handle_info({:publish, publish}, client) do
        {path, component} = parse_topic(publish.topic)
        Site.handle_publish(path, component, publish, client)
      end

      @impl true
      def handle_info({:connected, _publish}, client) do
        Logger.info("RSMP: Connected")
        Site.subscribe_to_topics(client)
        {:noreply, client}
      end

      @impl true
      def handle_info({:disconnected, _publish}, client) do
        Logger.warning("RSMP: Disconnected")
        {:noreply, client}
      end
    end
  end
end
