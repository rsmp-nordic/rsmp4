defmodule RSMP.Connection do
  use GenServer
  require Logger

  defstruct(
    emqtt: nil,
    id: nil,
    managers: %{},
    type: :site,
    connected: false,
    init_options: %{},
    offline_at: nil,
    connected_at: nil,
    auto_reconnect: true
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

  def connected?(id) do
    case RSMP.Registry.lookup_connection(id) do
      [{pid, _value}] ->
        try do
          GenServer.call(pid, :connected?, 2000)
        catch
          :exit, _ -> false
        end
      [] -> false
    end
  end

  def simulate_disconnect(id) do
    [{pid, _value}] = RSMP.Registry.lookup_connection(id)
    GenServer.cast(pid, :simulate_disconnect)
  end

  def simulate_reconnect(id) do
    [{pid, _value}] = RSMP.Registry.lookup_connection(id)
    GenServer.cast(pid, :simulate_reconnect)
  end

  def toggle_connection(id) do
    case connected?(id) do
      true -> simulate_disconnect(id)
      false -> simulate_reconnect(id)
    end
  end

  def get_socket_stats(id) do
    case RSMP.Registry.lookup_connection(id) do
      [{pid, _value}] ->
        try do
          GenServer.call(pid, :get_socket_stats, 2000)
        catch
          :exit, _ -> {:error, :unavailable}
        end
      [] -> {:error, :not_connected}
    end
  end

  # GenServer
  @impl GenServer
  def init({id, managers, options}) do
    Logger.debug("RSMP: starting emqtt")

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

    Process.flag(:trap_exit, true)

    {:ok, emqtt} = :emqtt.start_link(options)

    connection = new(emqtt: emqtt, id: id, managers: managers, type: type, init_options: options)

    send(self(), :connect)

    {:ok, connection}
  end

  @impl GenServer
  def terminate(_reason, connection) do
    publish_shutdown(connection)
    :ok
  end

  defp publish_shutdown(%{emqtt: emqtt, connected: true} = connection) when emqtt != nil do
    Process.unlink(emqtt)

    try do
      :emqtt.publish(
        emqtt,
        "#{connection.id}/presence",
        RSMP.Utility.to_payload("shutdown"),
        retain: true,
        qos: 1
      )

      :emqtt.disconnect(emqtt)
    catch
      _, _ -> :ok
    end
  end

  defp publish_shutdown(%{emqtt: emqtt} = connection) when emqtt != nil do
    Process.unlink(emqtt)
    Process.exit(emqtt, :shutdown)
    publish_shutdown_via_temp_connection(connection)
  end

  defp publish_shutdown(connection) do
    publish_shutdown_via_temp_connection(connection)
  end

  defp publish_shutdown_via_temp_connection(connection) do
    opts =
      connection.init_options
      |> Map.put(:clientid, "#{connection.id}_shutdown")
      |> Map.delete(:name)

    with {:ok, pid} <- :emqtt.start_link(opts),
         {:ok, _} <- :emqtt.connect(pid) do
      :emqtt.publish(
        pid,
        "#{connection.id}/presence",
        RSMP.Utility.to_payload("shutdown"),
        retain: true,
        qos: 1
      )

      :emqtt.disconnect(pid)
    else
      _ -> :ok
    end
  catch
    _, _ -> :ok
  end



  @impl GenServer
  def handle_call(:connected?, _from, connection) do
    {:reply, connection.connected, connection}
  end

  @impl GenServer
  def handle_call(:get_socket_stats, _from, %{emqtt: emqtt, connected: true} = connection)
      when emqtt != nil do
    try do
      info = :emqtt.info(emqtt)
      socket = info[:socket]

      case :emqtt_sock.getstat(socket, [:recv_oct, :send_oct]) do
        {:ok, stats} ->
          {:reply, {:ok, %{recv: stats[:recv_oct], send: stats[:send_oct]}}, connection}

        {:error, reason} ->
          Logger.warning("RSMP: getstat error: #{inspect(reason)}")
          {:reply, {:error, reason}, connection}
      end
    rescue
      e ->
        Logger.warning("RSMP: get_socket_stats rescue: #{inspect(e)}")
        {:reply, {:error, :unavailable}, connection}
    catch
      kind, reason ->
        Logger.warning("RSMP: get_socket_stats catch: #{inspect(kind)} #{inspect(reason)}")
        {:reply, {:error, :unavailable}, connection}
    end
  end

  def handle_call(:get_socket_stats, _from, connection) do
    {:reply, {:error, :not_connected}, connection}
  end

  @impl GenServer
  def handle_cast(:simulate_disconnect, connection) do
    if connection.emqtt do
      Process.unlink(connection.emqtt)

      if connection.connected do
        try do
          :emqtt.publish(
            connection.emqtt,
            "#{connection.id}/presence",
            RSMP.Utility.to_payload("offline"),
            retain: true,
            qos: 1
          )

          :emqtt.disconnect(connection.emqtt)
        catch
          _, _ -> :ok
        end
      end

      # Always kill the process to prevent emqtt auto-reconnect
      try do
        Process.exit(connection.emqtt, :kill)
      catch
        _, _ -> :ok
      end
    end

    Phoenix.PubSub.broadcast(RSMP.PubSub, "site:#{connection.id}", %{topic: "connected", connected: false})

    if connection.type == :supervisor do
      Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{connection.id}", %{topic: "connected", connected: false})
    end

    {:noreply, %{connection | emqtt: nil, connected: false, offline_at: DateTime.utc_now(), auto_reconnect: false}}
  end

  @impl GenServer
  def handle_cast(:simulate_reconnect, connection) do
    if !connection.connected do
      if connection.emqtt do
        Process.unlink(connection.emqtt)
        Process.exit(connection.emqtt, :kill)
      end

      opts = Map.delete(connection.init_options, :name)
      {:ok, emqtt} = :emqtt.start_link(opts)
      connection = %{connection | emqtt: emqtt, auto_reconnect: true}
      send(self(), :connect)
      {:noreply, connection}
    else
      {:noreply, connection}
    end
  end

  @impl GenServer
  def handle_cast({:publish_message, _topic, _data, _options, _properties}, %{connected: false} = connection) do
    {:noreply, connection}
  end

  def handle_cast({:publish_message, topic, data, %{retain: retain, qos: qos}=_options, %{}=properties}, connection) do
    topic_string = to_string(topic)

    if topic_string == "" do
      Logger.warning("RSMP: #{connection.id}: Attempted to publish to empty topic, data: #{inspect(data)}")
    end

    topic_without_id =
      case String.split(topic_string, "/", parts: 2) do
        [_id, rest] -> rest
        _ -> topic_string
      end

    Logger.debug(
      "RSMP: #{connection.id}: Publishing #{topic_without_id}: #{inspect(data)}"
    )

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
  def handle_info(:connect, %{emqtt: nil} = state) do
    {:noreply, state}
  end

  def handle_info(:connect, %{connected: true} = state) do
    {:noreply, state}
  end

  def handle_info(:connect, state) do
    case :emqtt.connect(state.emqtt) do
      {:ok, _} ->
        state = on_connected(state)
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("RSMP: Connection #{state.id} failed to connect to MQTT broker: #{inspect(reason)}. Retrying in 5s...")
        Process.send_after(self(), :connect, 5_000)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:connected, _publish}, %{emqtt: nil} = connection) do
    Logger.debug("RSMP: Connection #{connection.id} received stale :connected, ignoring")
    {:noreply, connection}
  end

  def handle_info({:connected, _publish}, connection) do
    {:noreply, on_connected(connection)}
  end

  @impl true
  def handle_info({:disconnected, _rc}, connection) do
    {:noreply, handle_connection_lost(connection)}
  end

  @impl true
  def handle_info({:disconnected, _rc, _props}, connection) do
    {:noreply, handle_connection_lost(connection)}
  end

  @impl true
  def handle_info({:EXIT, pid, _reason}, %{emqtt: pid} = connection) do
    Logger.warning("RSMP: Connection #{connection.id} emqtt process exited")
    connection = %{connection | emqtt: nil}
    {:noreply, handle_connection_lost(connection)}
  end

  def handle_info({:EXIT, pid, reason}, connection) do
    Logger.warning("RSMP: Connection #{connection.id} unexpected EXIT from #{inspect(pid)}: #{inspect(reason)}")
    {:noreply, connection}
  end

  def handle_info(:schedule_reconnect, %{auto_reconnect: true, emqtt: nil, connected: false} = connection) do
    Logger.debug("RSMP: Connection #{connection.id} auto-reconnecting")
    opts = connection.init_options |> Map.delete(:name)
    {:ok, emqtt} = :emqtt.start_link(opts)
    connection = %{connection | emqtt: emqtt}
    send(self(), :connect)
    {:noreply, connection}
  end

  def handle_info(:schedule_reconnect, connection) do
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

      type when type in ["command", "throttle"] ->
        dispatch_to_service(connection, topic, data, properties)

      "fetch" ->
        dispatch_fetch(connection, topic, data, properties)

      type when type in ["status", "alarm", "result", "channel", "replay", "history"] ->
        dispatch_to_manager(connection, topic, data, properties)

      _ ->
        Logger.warning("Ignoring unknown command type topic: '#{publish.topic}' => #{topic}")
    end

  end

  defp handle_connection_lost(connection) do
    Logger.warning("RSMP: Connection #{connection.id} lost")

    if connection.emqtt do
      Process.unlink(connection.emqtt)
      Process.exit(connection.emqtt, :kill)
    end

    Phoenix.PubSub.broadcast(RSMP.PubSub, "site:#{connection.id}", %{topic: "connected", connected: false})

    if connection.type == :supervisor do
      Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{connection.id}", %{topic: "connected", connected: false})
    end

    connection = %{connection | emqtt: nil, connected: false, offline_at: DateTime.utc_now()}

    if connection.auto_reconnect do
      Logger.debug("RSMP: Connection #{connection.id} scheduling reconnect in 5s")
      Process.send_after(self(), :schedule_reconnect, 5_000)
    end

    connection
  end

  defp on_connected(connection) do
    Logger.debug("RSMP: Connection #{connection.id} connected")
    subscribe_to_topics(connection)

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

    if connection.type == :site do
      trigger_channel_states(connection.id)
      trigger_channel_full(connection.id)
      since = replay_since(connection)
      trigger_channel_replay(connection.id, since)
    end

    Phoenix.PubSub.broadcast(RSMP.PubSub, "site:#{connection.id}", %{topic: "connected", connected: true})

    if connection.type == :supervisor do
      Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{connection.id}", %{topic: "connected", connected: true})
    end

    %{connection | connected: true, offline_at: nil, connected_at: DateTime.utc_now()}
  end

  defp trigger_services(id) do
    match_pattern = {{ {id, :service, :_}, :"$1", :_}, [], [:"$1"]}
    Registry.select(RSMP.Registry, [match_pattern])
    |> Enum.each(fn pid ->
       GenServer.cast(pid, :publish_all)
    end)
  end

  defp trigger_channel_states(id) do
    RSMP.Channels.list_channels(id)
    |> Enum.each(fn pid ->
      RSMP.Channel.publish_state(pid)
    end)
  end

  defp trigger_channel_full(id) do
    RSMP.Channels.list_channels(id)
    |> Enum.each(fn pid ->
      GenServer.cast(pid, :force_full)
    end)
  end

  defp trigger_channel_replay(id, since) do
    RSMP.Channels.list_channels(id)
    |> Enum.each(fn pid ->
      RSMP.Channel.replay(pid, since)
    end)
  end

  # Determine replay since-timestamp for reconnect.
  # If connected is still true (auto-reconnect: no disconnect message was received),
  # replay from connected_at (the start of the previous connection).
  # If offline_at is set (explicit disconnect message was received), use that.
  # Otherwise this is the first connect — no replay.
  defp replay_since(%{connected: true, connected_at: connected_at}), do: connected_at
  defp replay_since(%{offline_at: offline_at}), do: offline_at

  defp dispatch_fetch(connection, topic, data, properties) do
    from_ts = parse_datetime(data["from"])
    to_ts = parse_datetime(data["to"])
    response_topic = properties[:"Response-Topic"]
    correlation_data = properties[:"Correlation-Data"]

    case RSMP.Registry.lookup_channel(connection.id, topic.path.code, topic.channel_name) do
      [{pid, _}] ->
        GenServer.cast(pid, {:handle_fetch, from_ts, to_ts, response_topic, correlation_data})

      [] ->
        Logger.warning("#{connection.id}: Fetch for unknown channel: #{topic}")
        if response_topic do
          payload = %{"complete" => true}
          RSMP.Connection.publish_message(connection.id, response_topic, payload, %{retain: false, qos: 1}, %{command_id: correlation_data})
        end
    end
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  # implementation
  def subscribe_to_topics(connection) do
    emqtt = connection.emqtt
    id = connection.id
    # highest qos to be used when sending us messages
    qos = 2
    levels = Application.get_env(:rsmp, :topic_prefix_levels, 3)

    if connection.type == :site do
      {:ok, _, _} = :emqtt.subscribe(emqtt, {"#{id}/command/#", qos})
      {:ok, _, _} = :emqtt.subscribe(emqtt, {"#{id}/throttle/#", qos})
      {:ok, _, _} = :emqtt.subscribe(emqtt, {"#{id}/fetch/#", qos})
    end

    if connection.type == :supervisor do
      wildcard_id = List.duplicate("+", levels) |> Enum.join("/")

      {:ok, _, _} = :emqtt.subscribe(emqtt, {"#{wildcard_id}/presence", qos})
      {:ok, _, _} = :emqtt.subscribe(emqtt, {"#{wildcard_id}/status/#", qos})
      {:ok, _, _} = :emqtt.subscribe(emqtt, {"#{wildcard_id}/alarm/#", qos})
      {:ok, _, _} = :emqtt.subscribe(emqtt, {"#{wildcard_id}/result/#", qos})
      {:ok, _, _} = :emqtt.subscribe(emqtt, {"#{wildcard_id}/channel/#", qos})
      {:ok, _, _} = :emqtt.subscribe(emqtt, {"#{wildcard_id}/replay/#", qos})
      {:ok, _, _} = :emqtt.subscribe(emqtt, {"#{id}/history/#", qos})
    end
  end

  def dispatch_presence(connection, topic, _data) when topic.id == connection.id do
    #ignore message send by us
  end

  def dispatch_presence(connection, topic, status) when is_binary(status) do
    if RSMP.Registry.lookup_remote(connection.id, topic.id) == [] do
      Logger.debug("#{connection.id}: Adding remote for #{topic.id}")
      via = RSMP.Registry.via_remotes(connection.id)
      managers = []
      options = [type: connection.type, initial_presence: status]
      {:ok, _pid} = DynamicSupervisor.start_child(via, {RSMP.Remote.Node, {connection.id, topic.id, managers, options}})
    end
    RSMP.Remote.Node.State.update_online_status(connection.id, topic.id, status)

    if connection.type == :supervisor do
      case RSMP.Registry.lookup_site_data(connection.id, topic.id) do
        [{pid, _}] -> GenServer.cast(pid, {:presence_update, status})
        [] -> :ok
      end

      pub = %{topic: "presence", site: topic.id, presence: status}
      Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{connection.id}", pub)
      Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisor:#{connection.id}:#{topic.id}", pub)
    end
  end

  def dispatch_presence(connection, topic, online_status) do
    Logger.warning("#{connection.id}: Ignoring presence #{topic} with invalid state: #{inspect(online_status)}")
  end

  def dispatch_to_service(connection, topic, data, properties) do
    properties = %{
      response_topic: properties[:"Response-Topic"],
      command_id: properties[:"Correlation-Data"]
    }

    case topic.type do
      "throttle" when is_binary(topic.path.code) ->
        handle_channel_throttle(connection, topic.path.code, topic.channel_name, data, properties)

      _ ->
        case RSMP.Registry.lookup_service_by_code(topic.id, topic.path.code) do
          [{pid, _value}] ->
            case topic.type do
              "command" -> GenServer.call(pid, {:receive_command, topic, data, properties})
              _ -> :ok
            end

          _ ->
            Logger.warning("#{connection.id}: No service handling topic: #{topic}")
        end
    end
  end

  defp handle_channel_throttle(connection, code, channel_name, data, _properties) do
    action = if is_map(data), do: data["action"], else: nil

    cond do
      action not in ["start", "stop"] ->
        Logger.warning("#{connection.id}: Invalid throttle action: #{inspect(data)}")

      true ->
        channel_action = if action == "start", do: :start, else: :stop
        execute_channel_action(connection, code, channel_name, channel_action)
    end
  end

  defp execute_channel_action(connection, code, channel_name, action) do
    case RSMP.Registry.lookup_channel(connection.id, code, channel_name) do
      [{pid, _}] ->
        case action do
          :start -> RSMP.Channel.start_channel(pid)
          :stop -> RSMP.Channel.stop_channel(pid)
        end

        channel_segment = channel_name || "default"
        channel_key = "#{code}/#{channel_segment}"
        state = if action == :start, do: "running", else: "stopped"
        pub = %{topic: "channel", channel: channel_key, state: state}
        Phoenix.PubSub.broadcast(RSMP.PubSub, "site:#{connection.id}", pub)

      [] ->
        channel_label = channel_name || "default"
        Logger.warning("#{connection.id}: Channel not found: #{code}/#{channel_label}")
    end
  end

  def dispatch_to_manager(connection, topic, _data, _properties) when topic.id == connection.id do
    #ignore message send by us
  end

  def dispatch_to_manager(connection, topic, data, properties) do
    if RSMP.Registry.lookup_remote(connection.id, topic.id) == [] do
      Logger.warning("#{connection.id}: Ignoring message for unknown remote: #{topic}")
    else
      pid = case connection.managers[topic.path.code] do
        %{service_name: service_name, manager: manager_module} ->
          case RSMP.Registry.lookup_manager(connection.id, topic.id, service_name) do
            [{pid, _}] ->
              pid

            [] ->
              via = RSMP.Registry.via_managers(connection.id, topic.id)

              {:ok, pid} = DynamicSupervisor.start_child(
                via,
                {manager_module, {connection.id, topic.id, service_name, %{}}}
              )

              Logger.debug("RSMP: #{connection.id}: Added manager #{manager_module} for remote node #{topic.id}, code #{topic.path.code}")
              pid
          end

        nil ->
          # Unknown code — use Generic manager
          service_name = "generic"
          case RSMP.Registry.lookup_manager(connection.id, topic.id, service_name) do
            [{pid, _}] ->
              pid

            [] ->
              via = RSMP.Registry.via_managers(connection.id, topic.id)

              {:ok, pid} = DynamicSupervisor.start_child(
                via,
                {RSMP.Manager.Generic, {connection.id, topic.id, service_name, %{}}}
              )

              Logger.debug("RSMP: #{connection.id}: Added generic manager for remote node #{topic.id}, code #{topic.path.code}")
              pid
          end
      end

      case topic.type do
        "status" ->
          GenServer.cast(pid, {:receive_status, topic, data, properties})
          dispatch_to_site_data(connection, topic, data, properties)

        "alarm" ->
          GenServer.cast(pid, {:receive_alarm, topic, data, properties})
          dispatch_to_site_data(connection, topic, data, properties)

        "result" ->
          GenServer.cast(pid, {:receive_result, topic, data, properties})
          dispatch_to_site_data(connection, topic, data, properties)

        type when type in ["channel", "replay", "history"] ->
          dispatch_to_site_data(connection, topic, data, properties)

        _ ->
          Logger.warning("#{connection.id}: Ignoring unknown command type topic: '#{topic}'")
      end
    end
  end

  defp dispatch_to_site_data(connection, topic, data, properties) do
    case RSMP.Registry.lookup_site_data(connection.id, topic.id) do
      [{pid, _}] ->
        GenServer.cast(pid, {:receive, topic.type, topic, data, properties})

      [] ->
        Logger.warning("#{connection.id}: No site_data process for #{topic.id}, ignoring #{topic.type}")
    end
  end


  def publish_done(_data) do
    #Logger.debug("RSMP: Publish result: #{Kernel.inspect(data)}")
  end
end
