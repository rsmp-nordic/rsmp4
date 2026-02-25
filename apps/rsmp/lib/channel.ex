defmodule RSMP.Channel do
  @moduledoc """
  A channel defines how a particular status is published via MQTT.

  Each channel has:
  - code: module and status code (e.g. "groups")
  - channel_name: name to distinguish multiple channels (e.g. "live", "hourly")
  - attributes: map of attribute names to types (:on_change or :send_along)
  - update_rate: interval in ms for full retained updates (nil = on start only)
  - align_full_updates: align full update timer to wall-clock interval boundaries
  - delta_rate: :on_change | {:interval, ms} | :off
  - min_interval: minimum ms between delta publications
  - aggregation: :off | :sum | :count | :average | :median | :max | :min
  - default_on: whether the channel starts automatically
  - qos: MQTT QoS level (0 or 1)
  - prune_timeout: ms before auto-stopping when all consumers are offline (nil = no prune)
  """

  use GenServer
  require Logger

  # Max entries per MQTT message for replay/history batched responses
  @replay_batch_size 8

  defstruct [
    :id,              # node id
    :code,            # e.g. "tlc.groups"
    :channel_name,     # e.g. "live", "hourly", nil for single-channel statuses
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
    :replay_rate,     # messages/second for replay, nil = unlimited
    :history_rate,     # messages/second for history response, nil = unlimited
    :always_publish,  # boolean — always publish all values on every report (for counter data)
    :batch_interval,  # ms | nil — when set, accumulate events and publish as entries array
    buffer: [],           # list of %{ts, values, seq}, newest first
    buffer_size: 300,     # max buffer entries
    running: false,
    seq: 0,
    last_full: nil,        # last full values published
    last_delta_time: nil,  # timestamp of last delta publish
    pending_changes: %{},  # accumulator for coalesced changes
    pending_ts: nil,       # timestamp from the report that triggered pending changes
    full_timer: nil,
    delta_timer: nil,
    min_interval_timer: nil,
    aggregation_acc: nil,  # accumulator for aggregation
    active_send: nil,      # current in-progress fetch send: %{entries, response_topic, milestones}
    active_replay: nil,    # current in-progress replay: %{entries, topic, beginning}
    last_replayed_seq: nil, # last successfully replayed seq for interrupted replay resumption
    current_batch: [],     # accumulator for batched events
    batch_timer: nil       # timer ref for batch publishing
  ]

  # ---- Config struct for defining channels without runtime state ----

  defmodule Config do
    @moduledoc """
    Static configuration for a channel, used to define channels in service modules.
    """
    defstruct [
      :code,
      :channel_name,
      :component,
      attributes: %{},
      update_rate: nil,
      align_full_updates: false,
      delta_rate: :on_change,
      min_interval: 0,
      aggregation: :off,
      default_on: false,
      qos: 0,
      prune_timeout: nil,
      replay_rate: nil,
      history_rate: nil,
      always_publish: false,
      batch_interval: nil,
      gap_fetch: false
    ]
  end

  # ---- API ----

  def start_link({id, %Config{} = config}) do
    state = %__MODULE__{
      id: id,
      code: config.code,
      channel_name: config.channel_name,
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
      replay_rate: config.replay_rate,
      history_rate: config.history_rate,
      always_publish: config.always_publish,
      batch_interval: config.batch_interval,
      running: false
    }

    via = RSMP.Registry.via_channel(id, config.code, config.channel_name, config.component || [])
    GenServer.start_link(__MODULE__, state, name: via)
  end

  @doc "Start publishing data on this channel."
  def start_channel(pid), do: GenServer.call(pid, :start_channel)

  @doc "Stop publishing data on this channel."
  def stop_channel(pid), do: GenServer.call(pid, :stop_channel)

  @doc "Report new attribute values. Only call when the channel is running."
  def report(pid, values, ts \\ nil), do: GenServer.cast(pid, {:report, values, ts})

  @doc "Publish current channel running/stopped state."
  def publish_state(pid), do: GenServer.call(pid, :publish_state)

  @doc "Return the last published full values for this channel, or nil if nothing has been published yet."
  def get_last_full(pid), do: GenServer.call(pid, :get_last_full)

  @doc "Get current channel info."
  def info(pid), do: GenServer.call(pid, :info)

  @doc "Publish a full update immediately if the channel is running."
  def force_full(pid), do: GenServer.call(pid, :force_full)

  @doc "Replay buffered data since `since` (DateTime) on reconnect. Pass nil to skip replay."
  def replay(pid, since \\ nil), do: GenServer.cast(pid, {:replay, since})

  # ---- GenServer ----

  @impl GenServer
  def init(state) do
    if state.default_on do
      send(self(), :auto_start)
    else
      publish_channel_state(state)
    end

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:start_channel, _from, %{running: true} = state) do
    {:reply, {:error, :already_running}, state}
  end

  def handle_call(:start_channel, _from, state) do
    state = do_start(state)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call(:stop_channel, _from, %{running: false} = state) do
    {:reply, {:error, :not_running}, state}
  end

  def handle_call(:stop_channel, _from, state) do
    state = do_stop(state)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call(:info, _from, state) do
    info = %{
      code: state.code,
      channel_name: state.channel_name,
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

  def handle_call(:get_last_full, _from, state) do
    {:reply, state.last_full, state}
  end

  def handle_call(:publish_state, _from, state) do
    publish_channel_state(state)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_cast(:force_full, %{running: false} = state), do: {:noreply, state}

  def handle_cast(:force_full, state) do
    state = publish_full(state)
    {:noreply, state}
  end

  def handle_cast({:report, values, ts}, %{running: false} = state) do
    # Buffer the report with an incremented seq even though we're not publishing.
    # This lets the supervisor detect gaps in the seq numbers and request the
    # missing data via fetch/history once the channel is back on.
    state = buffer_without_publishing(values, ts, state)
    {:noreply, state}
  end

  def handle_cast({:report, values, ts}, state) do
    state = handle_report(values, ts, state)
    {:noreply, state}
  end

  def handle_cast({:replay, nil}, state) do
    {:noreply, state}
  end

  def handle_cast({:replay, since}, state) do
    state = start_replay(state, since)
    {:noreply, state}
  end

  def handle_cast({:handle_fetch, from_ts, to_ts, response_topic, correlation_data}, state) do
    beginning = buffer_beginning_for_range?(state.buffer, from_ts)
    history_end = buffer_end_for_range?(state.buffer, to_ts)
    new_milestone = %{to_ts: to_ts, correlation_data: correlation_data, beginning: beginning, end: history_end, sent_first: false}

    state =
      case state.active_send do
        nil ->
          entries = filter_buffer_by_range(state.buffer, from_ts, to_ts) |> Enum.reverse()

          if entries == [] do
            send_history_complete(state.id, response_topic, correlation_data, beginning: beginning, end: history_end)
            state
          else
            active_send = %{
              entries: entries,
              response_topic: response_topic,
              milestones: [new_milestone]
            }

            send(self(), :send_next_history_entry)
            %{state | active_send: active_send}
          end

        %{entries: [first | _] = remaining} = active_send ->
          # If the new fetch range is entirely before our current sending position, complete it immediately.
          already_done = to_ts != nil and DateTime.compare(first.ts, to_ts) != :lt

          if already_done do
            send_history_complete(state.id, response_topic, correlation_data, beginning: beginning, end: history_end)
            state
          else
            # Extend range: append buffer entries beyond the current queue's last entry.
            last_ts = List.last(remaining).ts

            extra_entries =
              filter_buffer_by_range(state.buffer, nil, to_ts)
              |> Enum.filter(fn e -> DateTime.compare(e.ts, last_ts) == :gt end)
              |> Enum.reverse()

            updated_milestones = insert_milestone_sorted(active_send.milestones, new_milestone)

            active_send = %{active_send |
              entries: remaining ++ extra_entries,
              milestones: updated_milestones
            }

            %{state | active_send: active_send}
          end
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

  def handle_info(:send_next_history_entry, state) do
    case state.active_send do
      nil ->
        {:noreply, state}

      %{entries: [entry | rest], milestones: milestones, response_topic: response_topic} = active_send ->
        # Complete milestones whose to_ts <= this entry's ts: all their entries have already been sent.
        {done, remaining_milestones} =
          Enum.split_with(milestones, fn ms ->
            ms.to_ts != nil and DateTime.compare(entry.ts, ms.to_ts) != :lt
          end)

        Enum.each(done, fn ms ->
          send_history_complete(state.id, response_topic, ms.correlation_data, beginning: ms[:beginning], end: ms[:end])
        end)

        # Use the first remaining milestone's correlation for this entry.
        first_milestone = List.first(remaining_milestones)
        correlation =
          case first_milestone do
            %{correlation_data: c} -> c
            nil -> nil
          end

        if correlation do
          next_entry_ts =
            case rest do
              [next | _] -> DateTime.to_iso8601(next.ts)
              [] -> nil
            end

          # Set complete: true on the last entry for this correlation.
          # If additional milestones also finish here (rest is empty), send bare complete for each.
          {entry_complete, extra_completes} =
            if rest == [] do
              {true, Enum.drop(remaining_milestones, 1)}
            else
              {false, []}
            end

          is_first_for_correlation = not first_milestone.sent_first

          entry_data = %{
            "values" => entry.values,
            "seq" => entry.seq,
            "ts" => DateTime.to_iso8601(entry.ts),
            "next_ts" => next_entry_ts
          }

          payload = %{"entries" => [entry_data], "complete" => entry_complete}

          # beginning: true on the first message if the first entry is the oldest in the buffer
          payload =
            if is_first_for_correlation and first_milestone[:beginning] do
              Map.put(payload, "beginning", true)
            else
              payload
            end

          # end: true on the final message if the last entry is the newest in the buffer
          payload =
            if entry_complete and first_milestone[:end] do
              Map.put(payload, "end", true)
            else
              payload
            end

          RSMP.Connection.publish_message(state.id, response_topic, payload, %{retain: false, qos: 1}, %{command_id: correlation})

          Enum.each(extra_completes, fn ms ->
            send_history_complete(state.id, response_topic, ms.correlation_data, beginning: ms[:beginning], end: ms[:end])
          end)
        end

        # Mark first entry as sent for the active milestone
        updated_milestones =
          case remaining_milestones do
            [ms | tail] -> [%{ms | sent_first: true} | tail]
            [] -> []
          end

        state =
          if rest == [] do
            %{state | active_send: nil}
          else
            sleep_ms = history_interval_ms(state.history_rate)

            if sleep_ms > 0 do
              Process.send_after(self(), :send_next_history_entry, sleep_ms)
            else
              send(self(), :send_next_history_entry)
            end

            %{state | active_send: %{active_send | entries: rest, milestones: updated_milestones}}
          end

        {:noreply, state}
    end
  end

  def handle_info(:send_next_replay_entry, state) do
    case state.active_replay do
      nil ->
        {:noreply, state}

      %{entries: entries, topic: topic, beginning: beginning, sent_first: sent_first} ->
        # Send entries in a chunk (up to @replay_batch_size at a time)
        {chunk, rest} = Enum.split(entries, replay_batch_size())

        is_last = rest == []
        is_first = not sent_first

        # Build batched payload with entries array
        formatted_entries =
          chunk
          |> Enum.with_index()
          |> Enum.map(fn {entry, idx} ->
            next_ts =
              cond do
                idx < length(chunk) - 1 ->
                  DateTime.to_iso8601(Enum.at(chunk, idx + 1).ts)
                not is_last ->
                  DateTime.to_iso8601(hd(rest).ts)
                true ->
                  nil
              end

            %{
              "values" => entry.values,
              "seq" => entry.seq,
              "ts" => DateTime.to_iso8601(entry.ts),
              "next_ts" => next_ts
            }
          end)

        payload =
          if is_last, do: %{"entries" => formatted_entries, "done" => true}, else: %{"entries" => formatted_entries}

        # beginning: true on the first message if the first entry is the oldest in the buffer
        payload =
          if is_first and beginning do
            Map.put(payload, "beginning", true)
          else
            payload
          end

        RSMP.Connection.publish_message(state.id, topic, payload, %{retain: false, qos: 1}, %{})

        last_in_chunk = List.last(chunk)
        state = %{state | last_replayed_seq: last_in_chunk.seq}

        state =
          if is_last do
            %{state | active_replay: nil}
          else
            # Scale delay by chunk size so replay_rate still limits entries/second
            sleep_ms = replay_interval_ms(state.replay_rate) * length(chunk)

            if sleep_ms > 0 do
              Process.send_after(self(), :send_next_replay_entry, sleep_ms)
            else
              send(self(), :send_next_replay_entry)
            end

            %{state | active_replay: %{entries: rest, topic: topic, beginning: beginning, sent_first: true}}
          end

        {:noreply, state}
    end
  end

  def handle_info(:batch_publish, state) do
    state = %{state | batch_timer: nil}
    state = flush_batch(state)
    {:noreply, state}
  end

  # ---- Internal ----

  defp do_start(state) do
    Logger.info("RSMP Channel: Starting #{channel_label(state)}")
    state = %{state | running: true, last_full: nil, pending_changes: %{}, aggregation_acc: nil}

    # Publish initial full update, unless:
    # - always_publish is set (event/counter channel, no accumulated state to snapshot)
    # - aggregation is active (first full comes when the aggregation timer fires)
    state =
      if not state.always_publish and state.aggregation == :off do
        request_and_publish_full(state)
      else
        state
      end

    # Schedule periodic full updates
    state = schedule_full_timer(state)

    # Schedule delta interval timer if needed
    state = schedule_delta_timer(state)

    publish_channel_state(state)

    state
  end

  defp do_stop(state) do
    Logger.info("RSMP Channel: Stopping #{channel_label(state)}")

    # Cancel timers
    state = cancel_timers(state)

    # Clear retained message
    publish_clear(state)

    state = %{state | running: false, last_full: nil, pending_changes: %{}, pending_ts: nil}
    publish_channel_state(state)
    state
  end

  defp request_and_publish_full(state) do
    # Get current values from the service
    case RSMP.Registry.lookup_service_by_code(state.id, state.code) do
      [{pid, _}] ->
        statuses = RSMP.Service.get_statuses(pid)
        values = statuses[state.code] || %{}

        # Filter to only attributes we care about
        values = Map.take(values, Map.keys(state.attributes))
        state = %{state | last_full: values}
        publish_full(state)

      [] ->
        Logger.warning("RSMP Channel: No service found for #{channel_label(state)}")
        state
    end
  end

  # Buffer values with a seq number but don't publish to MQTT.
  # Called when the channel is stopped to ensure seq gaps exist for the supervisor
  # to detect and fetch via history.
  defp buffer_without_publishing(values, ts, state) do
    values = Map.take(values, Map.keys(state.attributes))
    last_full = merge_values(state.last_full || %{}, values)
    seq = state.seq + 1
    entry = %{ts: ts || DateTime.utc_now(), values: values, seq: seq}
    buffer = [entry | state.buffer] |> Enum.take(state.buffer_size)
    %{state | seq: seq, last_full: last_full, buffer: buffer}
  end

  defp handle_report(values, ts, state) do
    # Filter to only attributes we care about
    values = Map.take(values, Map.keys(state.attributes))

    if state.aggregation != :off do
      handle_aggregated_report(values, state)
    else
      handle_live_report(values, ts, state)
    end
  end

  defp handle_live_report(values, ts, state) do
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

    # When always_publish is set, include all on_change attrs that are present in values
    # (for counter/volume data where each report is an independent event).
    attrs_for_delta =
      if state.always_publish do
        Enum.filter(on_change_attrs, fn attr -> Map.has_key?(values, attr) end)
      else
        changed_on_change
      end

    if attrs_for_delta == [] do
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
        attrs_for_delta
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
          state = %{state | pending_changes: pending, pending_ts: ts}
          maybe_publish_delta(state)

        :off ->
          state

        {:interval, _ms} ->
          # Accumulate for next interval tick
          pending = merge_values(state.pending_changes, delta_values)
          %{state | pending_changes: pending, pending_ts: ts}
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
    # For aggregated channels, accumulate values into lists per attribute
    acc = state.aggregation_acc || %{}

    acc =
      Enum.reduce(values, acc, fn {attr, value}, acc ->
        existing = Map.get(acc, attr, [])
        Map.put(acc, attr, existing ++ [value])
      end)

    %{state | aggregation_acc: acc}
  end

  # Compute aggregated values from the accumulator.
  # Returns a map with all attribute keys, defaulting to 0 for missing entries.
  defp compute_aggregation(:sum, acc, attributes) do
    acc = acc || %{}
    Enum.into(attributes, %{}, fn {attr, _type} ->
      values = Map.get(acc, attr, [])
      {attr, Enum.sum(values)}
    end)
  end

  defp compute_aggregation(:count, acc, attributes) do
    acc = acc || %{}
    Enum.into(attributes, %{}, fn {attr, _type} ->
      values = Map.get(acc, attr, [])
      {attr, length(values)}
    end)
  end

  defp compute_aggregation(:average, acc, attributes) do
    acc = acc || %{}
    Enum.into(attributes, %{}, fn {attr, _type} ->
      values = Map.get(acc, attr, [])
      {attr, if(values == [], do: 0, else: Enum.sum(values) / length(values))}
    end)
  end

  defp compute_aggregation(:max, acc, attributes) do
    acc = acc || %{}
    Enum.into(attributes, %{}, fn {attr, _type} ->
      values = Map.get(acc, attr, [])
      {attr, if(values == [], do: 0, else: Enum.max(values))}
    end)
  end

  defp compute_aggregation(:min, acc, attributes) do
    acc = acc || %{}
    Enum.into(attributes, %{}, fn {attr, _type} ->
      values = Map.get(acc, attr, [])
      {attr, if(values == [], do: 0, else: Enum.min(values))}
    end)
  end

  defp compute_aggregation(:median, acc, attributes) do
    acc = acc || %{}
    Enum.into(attributes, %{}, fn {attr, _type} ->
      values = Map.get(acc, attr, []) |> Enum.sort()
      {attr, if(values == [], do: 0, else: Enum.at(values, div(length(values), 2)))}
    end)
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
    # For aggregated channels, compute the result from the accumulator.
    # For regular channels, use the current full state.
    {data, state} =
      if state.aggregation != :off do
        aggregated = compute_aggregation(state.aggregation, state.aggregation_acc, state.attributes)
        {aggregated, %{state | aggregation_acc: nil, last_full: aggregated}}
      else
        {state.last_full || %{}, state}
      end

    seq = state.seq + 1
    ts = DateTime.utc_now()
    entry = %{ts: ts, values: data, seq: seq}

    # For counter/event channels (always_publish), the full is a state snapshot,
    # not a discrete event. Don't add it to the buffer so it won't appear in
    # replay/history responses as a phantom data point.
    buffer =
      if state.always_publish do
        state.buffer
      else
        [entry | state.buffer] |> Enum.take(state.buffer_size)
      end

    state = %{state | seq: seq, buffer: buffer}

    if state.batch_interval do
      # Accumulate into batch
      state = %{state | current_batch: state.current_batch ++ [Map.put(entry, :kind, :full)]}
      schedule_batch_timer(state)
    else
      payload = %{
        "values" => data,
        "seq" => seq,
        "ts" => DateTime.to_iso8601(ts)
      }

      topic = make_topic(state)

      RSMP.Connection.publish_message(
        state.id,
        topic,
        payload,
        %{retain: true, qos: state.qos},
        %{}
      )

      broadcast_channel_data(state, seq, "full")
      state
    end
  end

  defp publish_delta(state) do
    data = state.pending_changes
    seq = state.seq + 1
    ts = state.pending_ts || DateTime.utc_now()
    entry = %{ts: ts, values: data, seq: seq}

    now = System.monotonic_time(:millisecond)

    # Buffer the delta values (not the accumulated state) so replay sends per-event counts
    buffer = [entry | state.buffer] |> Enum.take(state.buffer_size)

    state = %{state |
      seq: seq,
      pending_changes: %{},
      pending_ts: nil,
      last_delta_time: now,
      min_interval_timer: nil,
      buffer: buffer
    }

    if state.batch_interval do
      # Accumulate into batch
      state = %{state | current_batch: state.current_batch ++ [Map.put(entry, :kind, :delta)]}
      schedule_batch_timer(state)
    else
      payload = %{
        "values" => data,
        "seq" => seq,
        "ts" => DateTime.to_iso8601(ts)
      }

      topic = make_topic(state)

      RSMP.Connection.publish_message(
        state.id,
        topic,
        payload,
        %{retain: false, qos: state.qos},
        %{}
      )

      broadcast_channel_data(state, seq, "delta")
      state
    end
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

  defp publish_channel_state(state) do
    topic = make_channel_state_topic(state)

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
    RSMP.Topic.new(state.id, "status", state.code, state.channel_name, state.component)
  end

  defp make_channel_state_topic(state) do
    channel_name =
      case state.channel_name do
        nil -> "default"
        "" -> "default"
        name -> to_string(name)
      end

    RSMP.Topic.new(state.id, "channel", state.code, channel_name, [])
  end

  defp make_replay_topic(state) do
    RSMP.Topic.new(state.id, "replay", state.code, state.channel_name, state.component)
  end

  defp start_replay(%{buffer: []} = state, _since) do
    topic = make_replay_topic(state)
    RSMP.Connection.publish_message(state.id, topic, %{"entries" => [], "done" => true}, %{retain: false, qos: 1}, %{})
    state
  end

  defp start_replay(state, since) do
    topic = make_replay_topic(state)

    entries =
      state.buffer
      |> Enum.reverse()
      |> Enum.filter(fn entry -> DateTime.compare(entry.ts, since) == :gt end)

    # Filter out already-replayed entries to resume interrupted replays
    entries =
      if state.last_replayed_seq do
        Enum.filter(entries, fn entry -> entry.seq > state.last_replayed_seq end)
      else
        entries
      end

    if entries == [] do
      topic = make_replay_topic(state)
      RSMP.Connection.publish_message(state.id, topic, %{"entries" => [], "done" => true}, %{retain: false, qos: 1}, %{})
      state
    else
      # beginning: true if the oldest buffered entry is newer than `since`,
      # i.e. the first entry sent is the oldest in the buffer — there is no earlier data.
      oldest_buffered = List.last(state.buffer)
      beginning = DateTime.compare(oldest_buffered.ts, since) == :gt

      active_replay = %{entries: entries, topic: topic, beginning: beginning, sent_first: false}
      send(self(), :send_next_replay_entry)
      %{state | active_replay: active_replay}
    end
  end

  defp replay_interval_ms(nil), do: 0
  defp replay_interval_ms(rate) when rate > 0, do: div(1000, rate)

  defp replay_batch_size, do: @replay_batch_size

  defp send_history_complete(id, response_topic, correlation_data, opts) do
    payload = %{"entries" => [], "complete" => true}
    payload = if opts[:beginning], do: Map.put(payload, "beginning", true), else: payload
    payload = if opts[:end], do: Map.put(payload, "end", true), else: payload
    RSMP.Connection.publish_message(id, response_topic, payload, %{retain: false, qos: 1}, %{command_id: correlation_data})
  end

  # Insert a milestone into a sorted list (earliest to_ts first, nil at the end).
  defp insert_milestone_sorted(milestones, new_milestone) do
    (milestones ++ [new_milestone])
    |> Enum.sort(fn a, b ->
      case {a.to_ts, b.to_ts} do
        {nil, _} -> false
        {_, nil} -> true
        {a_ts, b_ts} -> DateTime.compare(a_ts, b_ts) != :gt
      end
    end)
  end

  defp history_interval_ms(nil), do: 0
  defp history_interval_ms(rate) when rate > 0, do: div(1000, rate)

  # beginning: true if the first entry sent is the oldest in the buffer (nothing earlier exists).
  defp buffer_beginning_for_range?([], _from_ts), do: false
  defp buffer_beginning_for_range?(_buffer, nil), do: false
  defp buffer_beginning_for_range?(buffer, from_ts) do
    oldest = List.last(buffer)
    DateTime.compare(oldest.ts, from_ts) == :gt
  end

  # end: true if the last entry sent is the newest in the buffer (nothing later exists).
  defp buffer_end_for_range?([], _to_ts), do: false
  defp buffer_end_for_range?(_buffer, nil), do: false
  defp buffer_end_for_range?(buffer, to_ts) do
    newest = hd(buffer)
    DateTime.compare(newest.ts, to_ts) == :lt
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
    if state.batch_timer, do: Process.cancel_timer(state.batch_timer)
    state = flush_batch(state)
    %{state | full_timer: nil, delta_timer: nil, min_interval_timer: nil, batch_timer: nil}
  end

  defp schedule_batch_timer(%{batch_timer: nil, batch_interval: interval} = state)
       when is_integer(interval) do
    timer = Process.send_after(self(), :batch_publish, interval)
    %{state | batch_timer: timer}
  end

  defp schedule_batch_timer(state), do: state

  defp flush_batch(%{current_batch: []} = state), do: state

  defp flush_batch(state) do
    entries =
      Enum.map(state.current_batch, fn entry ->
        %{
          "values" => entry.values,
          "seq" => entry.seq,
          "ts" => DateTime.to_iso8601(entry.ts)
        }
      end)

    payload = %{"entries" => entries}
    topic = make_topic(state)

    # Retain only if the final entry is a complete data set (full update)
    last_entry = List.last(state.current_batch)
    retain = last_entry[:kind] == :full

    RSMP.Connection.publish_message(
      state.id,
      topic,
      payload,
      %{retain: retain, qos: state.qos},
      %{}
    )

    Enum.each(state.current_batch, fn entry ->
      kind = if entry[:kind] == :full, do: "full", else: "delta"
      broadcast_channel_data(state, entry.seq, kind)
    end)

    %{state | current_batch: []}
  end

  defp channel_label(state) do
    name = state.channel_name || "default"
    component = if state.component == [], do: "", else: "/" <> Enum.join(state.component, "/")
    "#{state.id}/status/#{state.code}/#{name}#{component}"
  end

  defp broadcast_channel_data(state, seq, kind) do
    channel_key = "#{state.code}/#{normalize_channel_name(state.channel_name)}"

    pub = %{
      topic: "channel_data",
      site: state.id,
      channel: channel_key,
      kind: kind,
      seq: seq
    }

    Phoenix.PubSub.broadcast(RSMP.PubSub, "site:#{state.id}", pub)
  end

  defp normalize_channel_name(nil), do: "default"
  defp normalize_channel_name(""), do: "default"
  defp normalize_channel_name(name), do: to_string(name)
end
