defmodule RSMP.Connection do
  use GenServer
  require Logger

  defstruct(
    emqtt: nil,
    id: nil,
    managers: %{},
    type: :site
  )

  def new(options), do: __struct__(options)

  # api
  def start_link({id, managers, options}) do
    via = RSMP.Registry.via_connection(id)
    GenServer.start_link(__MODULE__, {id, managers, options}, name: via)
  end

  def publish_message(id, topic, data, %{}=options, %{}=properties) do
    [{pid, _value}] = RSMP.Registry.lookup_connection(id)
    GenServer.cast(pid, {:publish_message, topic, data, options, properties})
  end

  # GenServer
  @impl GenServer
  def init({id, managers, options}) do
    Logger.info("RSMP: starting emqtt")

    type = Keyword.get(options, :type, :site)

    options =
      RSMP.Utility.client_options()
      |> Map.merge(%{
        name: String.to_atom(id),
        clientid: id,
        will_topic: "#{id}/presence",
        will_payload: RSMP.Utility.to_payload("offline"),
        will_retain: true
      })

    {:ok, emqtt} = :emqtt.start_link(options)
    # {:ok, _} = :emqtt.connect(emqtt)

    connection = new(emqtt: emqtt, id: id, managers: managers, type: type)
    # subscribe_to_topics(connection)

    send(self(), :connect)

    {:ok, connection}
  end

  @impl GenServer
  def handle_cast({:publish_message, topic, data, %{retain: retain, qos: qos}=options, %{}=properties}, connection) do
    Logger.info("RSMP: Publishing #{topic} with flags #{inspect(options)}: #{inspect(data)}")

    properties =
      if properties[:command_id] do
        %{"Correlation-Data": properties[:command_id]}
      else
        %{}
      end

    :emqtt.publish_async(
      connection.emqtt,
      to_string(topic),
      properties,
      RSMP.Utility.to_payload(data),
      [retain: retain, qos: qos],
      :infinity,
      &publish_done/1
    )

    {:noreply, connection}
  end

  # emqtt
  @impl true
  def handle_info(:connect, state) do
    case :emqtt.connect(state.emqtt) do
      {:ok, _} ->
        on_connected(state)
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("RSMP: Connection #{state.id} failed to connect to MQTT broker: #{inspect(reason)}. Retrying in 5s...")
        Process.send_after(self(), :connect, 5_000)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:connected, _publish}, connection) do
    on_connected(connection)
    {:noreply, connection}
  end

  @impl true
  def handle_info({:disconnected, _publish}, connection) do
    Logger.warning("RSMP: Disconnected")
    {:noreply, connection}
  end

  @impl true
  def handle_info({:publish, publish}, connection) do
    topic = RSMP.Topic.from_string(publish.topic)
    data = RSMP.Utility.from_payload(publish.payload)
    properties = publish.properties
    handle_publish(publish, topic, data, properties, connection)
    {:noreply, connection}
  end

  def handle_publish(publish, topic, data, properties, connection) do
    case topic.type do
      "presence" ->
        dispatch_presence(connection, topic, data)

      type when type in ["command", "reaction"] ->
        dispatch_to_service(connection, topic, data, properties)

      type when type in ["status", "alarm", "result"] ->
        dispatch_to_remote_service(connection, topic, data, properties)

      _ ->
        Logger.warning("Ignoring unknown command type topic: '#{publish.topic}' => #{topic}")
    end

  end

  defp on_connected(connection) do
    Logger.info("RSMP: Connection #{connection.id} connected")
    subscribe_to_topics(connection)

    # Publish Online state
    :emqtt.publish_async(
      connection.emqtt,
      "#{connection.id}/presence",
      %{},
      RSMP.Utility.to_payload("online"),
      [retain: true, qos: 1],
      :infinity,
      &publish_done/1
    )

    trigger_services(connection.id)
  end

  defp trigger_services(id) do
    match_pattern = {{ {id, :service, :_, :_}, :"$1", :_}, [], [:"$1"]}
    Registry.select(RSMP.Registry, [match_pattern])
    |> Enum.each(fn pid ->
       GenServer.cast(pid, :publish_all)
    end)
  end

  # implementation
  def subscribe_to_topics(connection) do
    emqtt = connection.emqtt
    id = connection.id
    # highest qos to be used when sending us messages
    qos = 2
    levels = Application.get_env(:rsmp, :topic_prefix_levels, 3)

    if connection.type == :site do
      {:ok, _, _} = :emqtt.subscribe(emqtt, {"#{id}/command/#", qos})
      {:ok, _, _} = :emqtt.subscribe(emqtt, {"#{id}/reaction/#", qos})
    end

    if connection.type == :supervisor do
      wildcard_id = List.duplicate("+", levels) |> Enum.join("/")

      {:ok, _, _} = :emqtt.subscribe(emqtt, {"#{wildcard_id}/presence/#", qos})
      {:ok, _, _} = :emqtt.subscribe(emqtt, {"#{wildcard_id}/status/#", qos})
      {:ok, _, _} = :emqtt.subscribe(emqtt, {"#{wildcard_id}/alarm/#", qos})
      {:ok, _, _} = :emqtt.subscribe(emqtt, {"#{wildcard_id}/result/#", qos})
    end
  end

  def dispatch_presence(connection, topic, _data) when topic.id == connection.id do
    #ignore message send by us
  end

  def dispatch_presence(connection, topic, status) when is_binary(status) do
    if RSMP.Registry.lookup_remote(connection.id, topic.id) == [] do
      Logger.warning("#{connection.id}: Adding remote for #{topic.id}")
      via = RSMP.Registry.via_remotes(connection.id)
      remote_services = []
      {:ok, _pid} = DynamicSupervisor.start_child(via, {RSMP.Remote.Node, {connection.id, topic.id, remote_services}})
    end
    RSMP.Remote.Node.State.update_online_status(connection.id, topic.id, status)
  end

  def dispatch_presence(connection, topic, online_status) do
    Logger.warning("#{connection.id}: Ignoring presence #{topic} with invalid state: #{inspect(online_status)}")
  end

  def dispatch_to_service(connection, topic, data, properties) do
    properties = %{
      response_topic: properties[:"Response-Topic"],
      command_id: properties[:"Correlation-Data"]
    }

    case RSMP.Registry.lookup_service(topic.id, topic.path.module, topic.path.component) do
      [{pid, _value}] ->
        case topic.type do
          "command" -> GenServer.call(pid, {:receive_command, topic, data, properties})
          "reaction" -> GenServer.call(pid, {:receive_reaction, topic, data, properties})
        end

      _ ->
        Logger.warning("#{connection.id}: No service handling topic: #{topic}")
    end
  end

  def dispatch_to_remote_service(connection, topic, _data, _properties) when topic.id == connection.id do
    #ignore message send by us
  end

  def dispatch_to_remote_service(connection, topic, data, properties) do
    if RSMP.Registry.lookup_remote(connection.id, topic.id) == [] do
      Logger.warning("#{connection.id}: Ignoring message for unknown remote: #{topic}")
    else
      pid = case RSMP.Registry.lookup_remote_service(connection.id, topic.id, topic.path.module, topic.path.component) do
        [{pid, _}] ->
          pid

        [] ->
          via = RSMP.Registry.via_remote_services(connection.id, topic.id)
          data = %{}
          component_type = List.first(topic.path.component)
          manager_module = connection.managers[component_type] || RSMP.Remote.Service.Generic

          {:ok, pid} = DynamicSupervisor.start_child(
            via,
            {manager_module, {connection.id, topic.id, topic.path.module, topic.path.component, data}}
          )

          Logger.info("#{connection.id}: Added remote service #{manager_module} for remote node #{topic.id}, component #{Enum.join(topic.path.component, "/")}")
          pid
      end

      case topic.type do
        "status" ->
          GenServer.cast(pid, {:receive_status, topic, data, properties})

        "alarm" ->
          GenServer.cast(pid, {:receive_alarm, topic, data, properties})

        "result" ->
          GenServer.cast(pid, {:receive_result, topic, data, properties})

        _ ->
          Logger.warning("#{connection.id}: Ignoring unknown command type topic: '#{topic}'")
      end
    end
  end

  # def publish_alarm(node, path) do
  #   flags = RSMP.Service.alarm_flag_string(node, path)
  #   Logger.info("RSMP: Sending alarm: #{path} #{flags}")

  #   :emqtt.publish_async(
  #     node.pid,
  #     "#{node.id}/alarm/#{path_string}",
  #     Utility.to_payload(Map.from_struct(node.alarms[path])),
  #     [retain: true, qos: 1],
  #     &publish_done/1
  #   )
  # end

  # def publish_response(node, path, response: response, properties: properties) do
  #   Logger.info("RSMP: Sending result: #{path}, #{inspect(response)}")
  #   # service, Topic, Properties, Payload, Opts, Timeout, Callback
  #   :emqtt.publish_async(
  #     node.mqtt,
  #     properties[:response_topic],
  #     %{ "Correlation-Data": properties[:command_id] },
  #     Utility.to_payload(response),
  #     [retain: true, qos: 1],
  #     :infinity,
  #     &Node.publish_done/1
  #   )
  # end

  def publish_done(_data) do
    #Logger.debug("RSMP: Publish result: #{Kernel.inspect(data)}")
  end
end
