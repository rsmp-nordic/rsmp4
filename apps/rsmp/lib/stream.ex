defmodule RSMP.Stream do
  @moduledoc """
  A stream defines how a particular status is published via MQTT.

  Each stream has:
  - code: module and status code (e.g. "groups")
  - stream_name: name to distinguish multiple streams (e.g. "live", "hourly")
  - attributes: map of attribute names to types (:on_change or :send_along)
  - update_rate: interval in ms for full retained updates (nil = on start only)
  - align_full_updates: align full update timer to wall-clock interval boundaries
  - delta_rate: :on_change | {:interval, ms} | :off
  - min_interval: minimum ms between delta publications
  - aggregation: :off | :sum | :count | :average | :median | :max | :min
  - default_on: whether the stream starts automatically
  - qos: MQTT QoS level (0 or 1)
  - prune_timeout: ms before auto-stopping when all consumers are offline (nil = no prune)
  """

  use GenServer
  require Logger

  defstruct [
    :id,              # node id
    :module,          # e.g. "tlc"
    :code,            # e.g. "groups"
    :stream_name,     # e.g. "live", "hourly", nil for single-stream statuses
    :component,       # e.g. [] or ["dl", "1"]
    :attributes,      # %{"signalgroupstatus" => :on_change, "cyclecounter" => :send_along, ...}
    :update_rate,     # ms | nil (full update interval)
    :align_full_updates, # boolean (align full timer to wall-clock boundaries)
    :delta_rate,      # :on_change | {:interval, ms} | :off
    :min_interval,    # ms (minimum gap between deltas)
    :aggregation,     # :off | :sum | :count | :average | :median | :max | :min
    :default_on,      # boolean
    :qos,             # 0 | 1
    :prune_timeout,   # ms | nil
    buffer: [],           # list of %{ts, values, seq}, newest first
    buffer_size: 300,     # max buffer entries
    running: false,
    seq: 0,
    last_full: nil,        # last full values published
    last_delta_time: nil,  # timestamp of last delta publish
    pending_changes: %{},  # accumulator for coalesced changes
    full_timer: nil,
    delta_timer: nil,
    min_interval_timer: nil,
    aggregation_acc: nil   # accumulator for aggregation
  ]

  # ---- Config struct for defining streams without runtime state ----

  defmodule Config do
    @moduledoc """
    Static configuration for a stream, used to define streams in service modules.
    """
    defstruct [
      :code,
      :stream_name,
      :component,
      attributes: %{},
      update_rate: nil,
      align_full_updates: false,
      delta_rate: :on_change,
      min_interval: 0,
      aggregation: :off,
      default_on: false,
      qos: 0,
      prune_timeout: nil
    ]
  end

  # ---- API ----

  def start_link({id, module, %Config{} = config}) do
    state = %__MODULE__{
      id: id,
      module: module,
      code: config.code,
      stream_name: config.stream_name,
      component: config.component || [],
      attributes: config.attributes,
      update_rate: config.update_rate,
      align_full_updates: config.align_full_updates,
      delta_rate: config.delta_rate,
      min_interval: config.min_interval,
      aggregation: config.aggregation,
      default_on: config.default_on,
      qos: config.qos,
      prune_timeout: config.prune_timeout,
      running: false
    }

    via = RSMP.Registry.via_stream(id, module, config.code, config.stream_name, config.component || [])
    GenServer.start_link(__MODULE__, state, name: via)
  end

  @doc "Start publishing data on this stream."
  def start_stream(pid), do: GenServer.call(pid, :start_stream)

  @doc "Stop publishing data on this stream."
  def stop_stream(pid), do: GenServer.call(pid, :stop_stream)

  @doc "Report new attribute values. Only call when the stream is running."
  def report(pid, values), do: GenServer.cast(pid, {:report, values})

  @doc "Publish current stream running/stopped state."
  def publish_state(pid), do: GenServer.call(pid, :publish_state)

  @doc "Get current stream info."
  def info(pid), do: GenServer.call(pid, :info)

  @doc "Publish a full update immediately if the stream is running."
  def force_full(pid), do: GenServer.call(pid, :force_full)

  @doc "Replay buffered data on reconnect."
  def replay(pid), do: GenServer.cast(pid, :replay)

  # ---- GenServer ----

  @impl GenServer
  def init(state) do
    if state.default_on do
      send(self(), :auto_start)
    else
      publish_stream_state(state)
    end

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:start_stream, _from, %{running: true} = state) do
    {:reply, {:error, :already_running}, state}
  end

  def handle_call(:start_stream, _from, state) do
    state = do_start(state)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call(:stop_stream, _from, %{running: false} = state) do
    {:reply, {:error, :not_running}, state}
  end

  def handle_call(:stop_stream, _from, state) do
    state = do_stop(state)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call(:info, _from, state) do
    info = %{
      code: state.code,
      stream_name: state.stream_name,
      module: state.module,
      component: state.component,
      running: state.running,
      seq: state.seq,
      attributes: state.attributes,
      update_rate: state.update_rate,
      align_full_updates: state.align_full_updates,
      delta_rate: state.delta_rate,
      min_interval: state.min_interval,
      aggregation: state.aggregation,
      default_on: state.default_on,
      qos: state.qos
    }

    {:reply, info, state}
  end

  def handle_call(:force_full, _from, %{running: false} = state) do
    {:reply, {:error, :not_running}, state}
  end

  def handle_call(:force_full, _from, state) do
    state = publish_full(state)
    {:reply, :ok, state}
  end

  def handle_call(:publish_state, _from, state) do
    publish_stream_state(state)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_cast({:report, _values}, %{running: false} = state) do
    # Ignore reports when not running
    {:noreply, state}
  end

  def handle_cast({:report, values}, state) do
    state = handle_report(values, state)
    {:noreply, state}
  end

  def handle_cast(:replay, state) do
    do_replay(state)
    {:noreply, state}
  end

  def handle_cast({:handle_fetch, from_ts, to_ts, response_topic, correlation_data}, state) do
    entries = filter_buffer_by_range(state.buffer, from_ts, to_ts)

    if entries == [] do
      payload = %{"complete" => true}
      RSMP.Connection.publish_message(state.id, response_topic, payload, %{retain: false, qos: 1}, %{command_id: correlation_data})
    else
      sorted = Enum.reverse(entries)
      last_idx = length(sorted) - 1

      sorted
      |> Enum.with_index()
      |> Enum.each(fn {entry, idx} ->
        payload = %{
          "values" => entry.values,
          "seq" => entry.seq,
          "ts" => DateTime.to_iso8601(entry.ts),
          "complete" => (idx == last_idx)
        }
        RSMP.Connection.publish_message(state.id, response_topic, payload, %{retain: false, qos: 1}, %{command_id: correlation_data})
        if idx < last_idx, do: Process.sleep(10)
      end)
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:auto_start, state) do
    state =
      if state.running do
        state
      else
        do_start(state)
      end

    {:noreply, state}
  end

  def handle_info(:full_update, state) do
    state = publish_full(state)
    state = schedule_full_timer(state)
    {:noreply, state}
  end

  def handle_info(:delta_interval, state) do
    state =
      if map_size(state.pending_changes) > 0 do
        publish_delta(state)
      else
        state
      end

    state = schedule_delta_timer(state)
    {:noreply, state}
  end

  def handle_info(:min_interval_expired, state) do
    state = %{state | min_interval_timer: nil}

    state =
      if map_size(state.pending_changes) > 0 do
        publish_delta(state)
      else
        state
      end

    {:noreply, state}
  end

  # ---- Internal ----

  defp do_start(state) do
    Logger.info("RSMP Stream: Starting #{stream_label(state)}")
    state = %{state | running: true, last_full: nil, pending_changes: %{}}

    # Request initial values from the service and publish full update
    state = request_and_publish_full(state)

    # Schedule periodic full updates
    state = schedule_full_timer(state)

    # Schedule delta interval timer if needed
    state = schedule_delta_timer(state)

    publish_stream_state(state)

    state
  end

  defp do_stop(state) do
    Logger.info("RSMP Stream: Stopping #{stream_label(state)}")

    # Cancel timers
    state = cancel_timers(state)

    # Clear retained message
    publish_clear(state)

    state = %{state | running: false, last_full: nil, pending_changes: %{}}
    publish_stream_state(state)
    state
  end

  defp request_and_publish_full(state) do
    # Get current values from the service
    case RSMP.Registry.lookup_service(state.id, state.module, state.component) do
      [{pid, _}] ->
        statuses = RSMP.Service.get_statuses(pid)
        values = statuses[state.code] || %{}

        # Filter to only attributes we care about
        values = Map.take(values, Map.keys(state.attributes))
        state = %{state | last_full: values}
        publish_full(state)

      [] ->
        Logger.warning("RSMP Stream: No service found for #{stream_label(state)}")
        state
    end
  end

  defp handle_report(values, state) do
    # Filter to only attributes we care about
    values = Map.take(values, Map.keys(state.attributes))

    if state.aggregation != :off do
      handle_aggregated_report(values, state)
    else
      handle_live_report(values, state)
    end
  end

  defp handle_live_report(values, state) do
    # Check if any :on_change attribute actually changed
    on_change_attrs =
      state.attributes
      |> Enum.filter(fn {_name, type} -> type == :on_change end)
      |> Enum.map(fn {name, _type} -> name end)

    changed_on_change =
      Enum.filter(on_change_attrs, fn attr ->
        new_val = Map.get(values, attr)
        old_val = get_in(state.last_full || %{}, [attr])
        on_change_changed?(new_val, old_val)
      end)

    if changed_on_change == [] do
      # No on_change attributes changed, just update last_full with send_along values
      last_full = merge_values(state.last_full || %{}, values)
      %{state | last_full: last_full}
    else
      # Build delta: changed on_change attrs + all send_along attrs
      send_along_attrs =
        state.attributes
        |> Enum.filter(fn {_name, type} -> type == :send_along end)
        |> Enum.map(fn {name, _type} -> name end)

      delta_values =
        changed_on_change
        |> Enum.reduce(%{}, fn attr, acc -> Map.put(acc, attr, values[attr]) end)
        |> then(fn delta ->
          Enum.reduce(send_along_attrs, delta, fn attr, acc ->
            val = Map.get(values, attr) || Map.get(state.last_full || %{}, attr)
            if val != nil, do: Map.put(acc, attr, val), else: acc
          end)
        end)

      # Update last_full
      last_full = merge_values(state.last_full || %{}, values)
      state = %{state | last_full: last_full}

      case state.delta_rate do
        :on_change ->
          # Coalesce with pending changes
          pending = merge_values(state.pending_changes, delta_values)
          state = %{state | pending_changes: pending}
          maybe_publish_delta(state)

        :off ->
          state

        {:interval, _ms} ->
          # Accumulate for next interval tick
          pending = merge_values(state.pending_changes, delta_values)
          %{state | pending_changes: pending}
      end
    end
  end

  defp on_change_changed?(new_val, _old_val) when is_nil(new_val), do: false

  defp on_change_changed?(new_val, old_val) when is_map(new_val) and is_map(old_val) do
    Enum.any?(new_val, fn {key, value} -> Map.get(old_val, key) != value end)
  end

  defp on_change_changed?(new_val, old_val) when is_map(new_val) do
    map_size(new_val) > 0 and new_val != old_val
  end

  defp on_change_changed?(new_val, old_val), do: new_val != old_val

  defp merge_values(old_values, new_values) do
    Map.merge(old_values, new_values, fn _key, old_value, new_value ->
      if is_map(old_value) and is_map(new_value) do
        Map.merge(old_value, new_value)
      else
        new_value
      end
    end)
  end

  defp handle_aggregated_report(values, state) do
    # For aggregated streams, accumulate values
    acc = state.aggregation_acc || %{}

    acc =
      Enum.reduce(values, acc, fn {attr, value}, acc ->
        existing = Map.get(acc, attr, [])
        Map.put(acc, attr, existing ++ [value])
      end)

    %{state | aggregation_acc: acc}
  end

  defp maybe_publish_delta(state) do
    now = System.monotonic_time(:millisecond)

    cond do
      state.min_interval <= 0 ->
        publish_delta(state)

      state.min_interval_timer != nil ->
        # Timer already running, changes will be published when it fires
        state

      state.last_delta_time == nil ->
        publish_delta(state)

      now - state.last_delta_time >= state.min_interval ->
        publish_delta(state)

      true ->
        # Schedule min_interval timer
        remaining = state.min_interval - (now - state.last_delta_time)
        timer = Process.send_after(self(), :min_interval_expired, max(remaining, 1))
        %{state | min_interval_timer: timer}
    end
  end

  defp publish_full(state) do
    data = state.last_full || %{}
    seq = state.seq + 1

    payload = %{
      "values" => data,
      "seq" => seq
    }

    topic = make_topic(state)

    RSMP.Connection.publish_message(
      state.id,
      topic,
      payload,
      %{retain: true, qos: state.qos},
      %{}
    )

    broadcast_stream_data(state, seq, "full")

    entry = %{ts: DateTime.utc_now(), values: data, seq: seq}
    buffer = [entry | state.buffer] |> Enum.take(state.buffer_size)
    %{state | seq: seq, buffer: buffer}
  end

  defp publish_delta(state) do
    data = state.pending_changes
    seq = state.seq + 1

    payload = %{
      "values" => data,
      "seq" => seq
    }

    topic = make_topic(state)

    RSMP.Connection.publish_message(
      state.id,
      topic,
      payload,
      %{retain: false, qos: state.qos},
      %{}
    )

    broadcast_stream_data(state, seq, "delta")

    now = System.monotonic_time(:millisecond)

    # Buffer the full reconstructed state (not just the delta) for replay/history
    full_values = state.last_full || %{}
    entry = %{ts: DateTime.utc_now(), values: full_values, seq: seq}
    buffer = [entry | state.buffer] |> Enum.take(state.buffer_size)

    %{state |
      seq: seq,
      pending_changes: %{},
      last_delta_time: now,
      min_interval_timer: nil,
      buffer: buffer
    }
  end

  defp publish_clear(state) do
    topic = make_topic(state)

    RSMP.Connection.publish_message(
      state.id,
      topic,
      nil,
      %{retain: true, qos: state.qos},
      %{}
    )
  end

  defp publish_stream_state(state) do
    topic = make_stream_state_topic(state)

    payload = %{
      "state" => if(state.running, do: "running", else: "stopped")
    }

    RSMP.Connection.publish_message(
      state.id,
      topic,
      payload,
      %{retain: true, qos: 1},
      %{}
    )
  end

  defp make_topic(state) do
    RSMP.Topic.new(state.id, "status", state.module, state.code, state.stream_name, state.component)
  end

  defp make_stream_state_topic(state) do
    stream_name =
      case state.stream_name do
        nil -> "default"
        "" -> "default"
        name -> to_string(name)
      end

    RSMP.Topic.new(state.id, "channel", state.module, state.code, stream_name, [])
  end

  defp make_replay_topic(state) do
    RSMP.Topic.new(state.id, "replay", state.module, state.code, state.stream_name, state.component)
  end

  defp do_replay(%{buffer: []} = _state), do: :ok

  defp do_replay(state) do
    topic = make_replay_topic(state)
    entries = Enum.reverse(state.buffer)
    last_idx = length(entries) - 1

    entries
    |> Enum.with_index()
    |> Enum.each(fn {entry, idx} ->
      payload = %{
        "values" => entry.values,
        "seq" => entry.seq,
        "ts" => DateTime.to_iso8601(entry.ts),
        "complete" => (idx == last_idx)
      }
      RSMP.Connection.publish_message(state.id, topic, payload, %{retain: false, qos: 1}, %{})
      if idx < last_idx, do: Process.sleep(10)
    end)
  end

  defp filter_buffer_by_range(buffer, nil, nil), do: buffer

  defp filter_buffer_by_range(buffer, from_ts, to_ts) do
    buffer
    |> Enum.filter(fn entry ->
      from_ok = is_nil(from_ts) or DateTime.compare(entry.ts, from_ts) != :lt
      to_ok = is_nil(to_ts) or DateTime.compare(entry.ts, to_ts) == :lt
      from_ok and to_ok
    end)
  end

  defp schedule_full_timer(%{update_rate: nil} = state), do: state

  defp schedule_full_timer(state) do
    if state.full_timer, do: Process.cancel_timer(state.full_timer)
    timer = Process.send_after(self(), :full_update, full_timer_delay_ms(state))
    %{state | full_timer: timer}
  end

  defp full_timer_delay_ms(%{update_rate: update_rate, align_full_updates: true})
       when is_integer(update_rate) and update_rate > 0 do
    now_ms = System.system_time(:millisecond)
    remainder = rem(now_ms, update_rate)

    if remainder == 0 do
      update_rate
    else
      update_rate - remainder
    end
  end

  defp full_timer_delay_ms(%{update_rate: update_rate}), do: update_rate

  defp schedule_delta_timer(%{delta_rate: {:interval, ms}} = state) do
    if state.delta_timer, do: Process.cancel_timer(state.delta_timer)
    timer = Process.send_after(self(), :delta_interval, ms)
    %{state | delta_timer: timer}
  end

  defp schedule_delta_timer(state), do: state

  defp cancel_timers(state) do
    if state.full_timer, do: Process.cancel_timer(state.full_timer)
    if state.delta_timer, do: Process.cancel_timer(state.delta_timer)
    if state.min_interval_timer, do: Process.cancel_timer(state.min_interval_timer)
    %{state | full_timer: nil, delta_timer: nil, min_interval_timer: nil}
  end

  defp stream_label(state) do
    name = state.stream_name || "default"
    component = if state.component == [], do: "", else: "/" <> Enum.join(state.component, "/")
    "#{state.id}/status/#{state.module}.#{state.code}/#{name}#{component}"
  end

  defp broadcast_stream_data(state, seq, kind) do
    stream_key = "#{state.module}.#{state.code}/#{normalize_stream_name(state.stream_name)}"

    pub = %{
      topic: "stream_data",
      site: state.id,
      stream: stream_key,
      kind: kind,
      seq: seq
    }

    Phoenix.PubSub.broadcast(RSMP.PubSub, "site:#{state.id}", pub)
  end

  defp normalize_stream_name(nil), do: "default"
  defp normalize_stream_name(""), do: "default"
  defp normalize_stream_name(name), do: to_string(name)
end
