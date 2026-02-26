defmodule RSMP.ChannelTest do
  use ExUnit.Case

  # MockConnection to intercept messages published via RSMP.Connection
  defmodule MockConnection do
    use GenServer

    def start_link({id, test_pid}) do
      via = RSMP.Registry.via_connection(id)
      GenServer.start_link(__MODULE__, test_pid, name: via)
    end

    def init(test_pid) do
      {:ok, test_pid}
    end

    def handle_cast({:publish_message, topic, data, options, _properties}, test_pid) do
      send(test_pid, {:published, topic, data, options})
      {:noreply, test_pid}
    end
  end

  setup do
    if Process.whereis(RSMP.Registry) == nil do
      RSMP.Registry.start_link()
    end
    :ok
  end

  describe "Channel lifecycle" do
    test "channel starts and stops" do
      id = "channel_lifecycle_test"
      start_supervised!({MockConnection, {id, self()}})

      # Start a TLC service so the channel can fetch initial values
      initial_data = %{plan: 1, plans: %{1 => %{}, 2 => %{}}}
      start_supervised!({RSMP.Service.TLC, {id, "tlc", initial_data}})

      config = %RSMP.Channel.Config{
        code: "tlc.plan",
        channel_name: nil,
        attributes: %{
          "status" => :on_change,
          "source" => :send_along
        },
        update_rate: nil,
        delta_rate: :on_change,
        min_interval: 0,
        default_on: false,
        qos: 1
      }

      {:ok, channel_pid} = RSMP.Channel.start_link({id, config})

      assert_receive {:published, topic, state_data, state_options}
      assert to_string(topic) == "#{id}/channel/tlc.plan/default"
      assert state_data == %{"state" => "stopped"}
      assert state_options.retain == true
      assert state_options.qos == 1

      # Channel should not be running
      info = RSMP.Channel.info(channel_pid)
      assert info.running == false
      assert info.seq == 0

      # Start the channel
      assert :ok = RSMP.Channel.start_channel(channel_pid)

      # Should have published a full update
      assert_receive {:published, topic, data, options}
      assert to_string(topic) == "#{id}/status/tlc.plan"
      entry = hd(data["entries"])
      assert entry["values"]["status"] == 1
      assert entry["seq"] == 1
      assert options.retain == true

      assert_receive {:published, topic, state_data, state_options}
      assert to_string(topic) == "#{id}/channel/tlc.plan/default"
      assert state_data == %{"state" => "running"}
      assert state_options.retain == true
      assert state_options.qos == 1

      # Starting again should fail
      assert {:error, :already_running} = RSMP.Channel.start_channel(channel_pid)

      info = RSMP.Channel.info(channel_pid)
      assert info.running == true
      assert info.seq == 1

      # Stop the channel
      assert :ok = RSMP.Channel.stop_channel(channel_pid)

      # Should publish empty retained message to clear
      assert_receive {:published, _topic, nil, %{retain: true}}

      assert_receive {:published, topic, state_data, state_options}
      assert to_string(topic) == "#{id}/channel/tlc.plan/default"
      assert state_data == %{"state" => "stopped"}
      assert state_options.retain == true
      assert state_options.qos == 1

      info = RSMP.Channel.info(channel_pid)
      assert info.running == false
      assert info.seq == 1

      # Start again, seq should continue instead of resetting
      assert :ok = RSMP.Channel.start_channel(channel_pid)

      assert_receive {:published, _topic, data, _options}
      entry = hd(data["entries"])
      assert entry["values"]["status"] == 1
      assert entry["seq"] == 2

      assert_receive {:published, topic, state_data, state_options}
      assert to_string(topic) == "#{id}/channel/tlc.plan/default"
      assert state_data == %{"state" => "running"}
      assert state_options.retain == true
      assert state_options.qos == 1

      info = RSMP.Channel.info(channel_pid)
      assert info.running == true
      assert info.seq == 2

      # Stopping again should fail
      assert :ok = RSMP.Channel.stop_channel(channel_pid)
      assert_receive {:published, _topic, nil, %{retain: true}}

      assert_receive {:published, topic, state_data, state_options}
      assert to_string(topic) == "#{id}/channel/tlc.plan/default"
      assert state_data == %{"state" => "stopped"}
      assert state_options.retain == true
      assert state_options.qos == 1

      assert {:error, :not_running} = RSMP.Channel.stop_channel(channel_pid)
    end

    test "channel with default_on starts automatically" do
      id = "channel_default_on_test"
      start_supervised!({MockConnection, {id, self()}})

      initial_data = %{plan: 2, plans: %{1 => %{}, 2 => %{}}}
      start_supervised!({RSMP.Service.TLC, {id, "tlc", initial_data}})

      config = %RSMP.Channel.Config{
        code: "tlc.plan",
        channel_name: nil,
        attributes: %{
          "status" => :on_change,
          "source" => :send_along
        },
        update_rate: nil,
        delta_rate: :on_change,
        min_interval: 0,
        default_on: true,
        qos: 1
      }

      {:ok, _channel_pid} = RSMP.Channel.start_link({id, config})

      # Should auto-start and publish a full update
      assert_receive {:published, _topic, data, _options}, 500
      assert hd(data["entries"])["values"]["status"] == 2

      assert_receive {:published, topic, state_data, state_options}, 500
      assert to_string(topic) == "#{id}/channel/tlc.plan/default"
      assert state_data == %{"state" => "running"}
      assert state_options.retain == true
      assert state_options.qos == 1
    end
  end

  describe "Send on Change / Send Along" do
    test "on_change attributes trigger delta, send_along attributes are included" do
      id = "channel_change_test"
      start_supervised!({MockConnection, {id, self()}})

      initial_data = %{plan: 1, plans: %{1 => %{}, 2 => %{}}}
      start_supervised!({RSMP.Service.TLC, {id, "tlc", initial_data}})

      config = %RSMP.Channel.Config{
        code: "tlc.groups",
        channel_name: "live",
        attributes: %{
          "signalgroupstatus" => :on_change,
          "stage" => :on_change,
          "cyclecounter" => :send_along
        },
        update_rate: nil,
        delta_rate: :on_change,
        min_interval: 0,
        default_on: false,
        qos: 0
      }

      {:ok, channel_pid} = RSMP.Channel.start_link({id, config})

      assert_receive {:published, topic, state_data, state_options}
      assert to_string(topic) == "#{id}/channel/tlc.groups/live"
      assert state_data == %{"state" => "stopped"}
      assert state_options.retain == true
      assert state_options.qos == 1

      :ok = RSMP.Channel.start_channel(channel_pid)

      # Consume the initial full update
      assert_receive {:published, _topic, %{"entries" => [_ | _]}, _options}
      assert_receive {:published, _topic, %{"state" => "running"}, _options}

      # Report values where an on_change attr changes
      RSMP.Channel.report(channel_pid, %{
        "signalgroupstatus" => %{"1" => "G", "2" => "G", "3" => "G", "4" => "R", "5" => "R"},
        "stage" => 1,
        "cyclecounter" => 42
      })

      # Should get a delta with the changed on_change attrs + send_along attrs
      assert_receive {:published, topic, data, options}, 500
      entry = hd(data["entries"])
      assert to_string(topic) =~ "tlc.groups/live"
      assert entry["values"]["signalgroupstatus"] == %{"1" => "G", "2" => "G", "3" => "G", "4" => "R", "5" => "R"}
      assert entry["values"]["stage"] == 1
      assert entry["values"]["cyclecounter"] == 42
      assert options.retain == false

      # Report only cyclecounter change (send_along) - should NOT trigger delta
      RSMP.Channel.report(channel_pid, %{
        "signalgroupstatus" => %{"1" => "G", "2" => "G", "3" => "G", "4" => "R", "5" => "R"},
        "stage" => 1,
        "cyclecounter" => 43
      })

      # No delta should be published (cyclecounter is send_along, not a trigger)
      refute_receive {:published, _, %{"entries" => _}, %{retain: false}}, 200

      # Report signalgroupstatus change - should trigger delta with updated cyclecounter
      RSMP.Channel.report(channel_pid, %{
        "signalgroupstatus" => %{"4" => "G"},
        "stage" => 1,
        "cyclecounter" => 44
      })

      assert_receive {:published, _topic, data, _options}, 500
      entry = hd(data["entries"])
      assert entry["values"]["signalgroupstatus"] == %{"4" => "G"}
      # cyclecounter should be the latest value, sent along
      assert entry["values"]["cyclecounter"] == 44
      # stage didn't change so it should NOT be in the delta
      refute Map.has_key?(entry["values"], "stage")
    end
  end

  describe "Channel topic formatting" do
    test "topic includes channel name when present" do
      topic = RSMP.Topic.new("site1", "status", "tlc.groups", "live")
      assert to_string(topic) == "site1/status/tlc.groups/live"
    end

    test "topic omits channel name when nil" do
      topic = RSMP.Topic.new("site1", "status", "tlc.plan")
      assert to_string(topic) == "site1/status/tlc.plan"
    end

    test "topic includes channel name" do
      topic = RSMP.Topic.new("site1", "status", "tlc.traffic", "hourly")
      assert to_string(topic) == "site1/status/tlc.traffic/hourly"
    end
  end

  describe "TLC channel definitions" do
    test "TLC node starts with expected channel configs" do
      id = "channel_tlc_test"

      # Start MockConnection before the node
      start_supervised!({MockConnection, {id, self()}})

      # Start TLC node without its own connection (use nil to skip connection)
      {:ok, _} = RSMP.Node.TLC.start_link(id, connection_module: nil)

      # Wait for channels to be started
      Process.sleep(200)

      channels = RSMP.Node.TLC.get_channels(id)
      assert length(channels) == 5

      # Find specific channels
      groups_live = Enum.find(channels, &(&1.code == "tlc.groups" and &1.channel_name == "live"))
      plan_channel = Enum.find(channels, &(&1.code == "tlc.plan"))
      plans_channel = Enum.find(channels, &(&1.code == "tlc.plans"))
      traffic_live = Enum.find(channels, &(&1.code == "traffic.volume" and &1.channel_name == "live"))
      traffic_5s = Enum.find(channels, &(&1.code == "traffic.volume" and &1.channel_name == "5s"))

      assert groups_live != nil
      assert groups_live.running == false  # default_on: false
      assert groups_live.qos == 0

      assert plan_channel != nil
      assert plan_channel.running == true  # default_on: true
      assert plan_channel.channel_name == nil

      assert plans_channel != nil
      assert plans_channel.running == true  # default_on: true

      assert traffic_live != nil
      assert traffic_live.running == true
      assert traffic_live.delta_rate == :on_change

      assert traffic_5s != nil
      assert traffic_5s.running == true
      assert traffic_5s.delta_rate == :off
    end

    test "stopped tlc.plan channel does not publish on plan switch" do
      id = "channel_plan_stop_test"

      start_supervised!({MockConnection, {id, self()}})
      {:ok, _} = RSMP.Node.TLC.start_link(id, connection_module: nil)

      Process.sleep(200)

      # Drain startup publications (full updates from default-on channels)
      drain_published_messages()

      assert :ok = RSMP.Node.TLC.stop_channel(id, "tlc.plan", nil)

      # Channel stop publishes retained nil to clear stale data
      assert_receive {:published, topic, nil, _options}, 500
      assert to_string(topic) == "#{id}/status/tlc.plan"

      # Changing plan should not publish status while channel is stopped
      assert %{status: "ok", plan: 2} = RSMP.Node.TLC.set_plan(id, 2)

      refute_receive {:published, %RSMP.Topic{type: "status", path: %RSMP.Path{code: "tlc.plan"}}, _data, _options}, 400
    end
  end

  defp drain_published_messages do
    receive do
      {:published, _topic, _data, _options} -> drain_published_messages()
    after
      0 -> :ok
    end
  end

  describe "Fetch / History" do
    test "handle_fetch returns buffered entries as history messages" do
      id = "channel_fetch_test"
      start_supervised!({MockConnection, {id, self()}})

      initial_data = %{plan: 1, plans: %{1 => %{}, 2 => %{}}}
      start_supervised!({RSMP.Service.TLC, {id, "tlc", initial_data}})

      config = %RSMP.Channel.Config{
        code: "tlc.plan",
        channel_name: nil,
        attributes: %{
          "status" => :on_change,
          "source" => :send_along
        },
        update_rate: nil,
        delta_rate: :on_change,
        min_interval: 0,
        default_on: false,
        qos: 1,
        replay_rate: 4,
        history_rate: 4
      }

      {:ok, channel_pid} = RSMP.Channel.start_link({id, config})

      # Receive and discard channel state
      assert_receive {:published, _, _, _}

      # Start and get initial full update + channel state
      :ok = RSMP.Channel.start_channel(channel_pid)
      assert_receive {:published, _, _, _}  # full update
      assert_receive {:published, _, _, _}  # channel state

      drain_published_messages()

      # Now issue a fetch for the full time range
      response_topic = "supervisor1/history/tlc.plan"
      correlation_id = "fetch-test-123"
      from_ts = DateTime.add(DateTime.utc_now(), -60)
      to_ts = DateTime.add(DateTime.utc_now(), 60)

      GenServer.cast(channel_pid, {:handle_fetch, from_ts, to_ts, response_topic, correlation_id})

      # Wait for the spawned process to publish
      Process.sleep(500)

      # Collect all history messages
      history_msgs = collect_published_messages()

      # Should have received at least 1 history message (the initial full = 1 entry)
      assert length(history_msgs) >= 1

      # Last message should have complete: true
      {_topic, last_data, _opts} = List.last(history_msgs)
      assert last_data["complete"] == true

      # All messages should be on the response topic
      Enum.each(history_msgs, fn {topic, _data, _opts} ->
        assert to_string(topic) == response_topic
      end)
    end

    test "handle_fetch returns complete: true for empty buffer" do
      id = "channel_fetch_empty_test"
      start_supervised!({MockConnection, {id, self()}})

      initial_data = %{plan: 1, plans: %{1 => %{}, 2 => %{}}}
      start_supervised!({RSMP.Service.TLC, {id, "tlc", initial_data}})

      config = %RSMP.Channel.Config{
        code: "tlc.plan",
        channel_name: nil,
        attributes: %{
          "status" => :on_change
        },
        update_rate: nil,
        delta_rate: :on_change,
        min_interval: 0,
        default_on: false,
        qos: 1,
        history_rate: 4
      }

      {:ok, channel_pid} = RSMP.Channel.start_link({id, config})

      # Just receive the initial channel state
      assert_receive {:published, _, _, _}

      drain_published_messages()

      # Fetch with a future time range that won't match anything
      response_topic = "supervisor1/history/tlc.plan"
      correlation_id = "fetch-empty-123"
      from_ts = DateTime.add(DateTime.utc_now(), 3600)
      to_ts = DateTime.add(DateTime.utc_now(), 7200)

      GenServer.cast(channel_pid, {:handle_fetch, from_ts, to_ts, response_topic, correlation_id})

      # Should get a single complete: true response with empty entries
      assert_receive {:published, topic, data, _opts}, 500
      assert to_string(topic) == response_topic
      assert data == %{"entries" => [], "complete" => true}
    end

    test "reports while stopped are buffered with seq but not published" do
      id = "channel_buffer_stopped_test"
      start_supervised!({MockConnection, {id, self()}})

      initial_data = %{plan: 1, plans: %{1 => %{}, 2 => %{}}}
      start_supervised!({RSMP.Service.TLC, {id, "tlc", initial_data}})

      config = %RSMP.Channel.Config{
        code: "tlc.groups",
        channel_name: "live",
        attributes: %{
          "signalgroupstatus" => :on_change,
          "cyclecounter" => :send_along
        },
        update_rate: nil,
        delta_rate: :on_change,
        min_interval: 0,
        default_on: false,
        qos: 0,
        history_rate: nil
      }

      {:ok, channel_pid} = RSMP.Channel.start_link({id, config})
      assert_receive {:published, _, _, _}  # channel state

      # Channel is stopped — reports should buffer but not publish
      RSMP.Channel.report(channel_pid, %{"signalgroupstatus" => %{"1" => "G1"}, "cyclecounter" => 1})
      Process.sleep(10)
      RSMP.Channel.report(channel_pid, %{"signalgroupstatus" => %{"1" => "G2"}, "cyclecounter" => 2})
      Process.sleep(10)

      # No status messages should be published while stopped
      refute_receive {:published, _, _, _}, 100

      # Now start the channel — it publishes a full update
      :ok = RSMP.Channel.start_channel(channel_pid)
      assert_receive {:published, _, _, _}  # full update
      assert_receive {:published, _, _, _}  # channel state

      drain_published_messages()

      # Fetch the buffer — should contain the 2 buffered entries + 1 full = 3
      response_topic = "supervisor1/history/tlc.groups/live"
      correlation_id = "fetch-buffered-123"
      from_ts = DateTime.add(DateTime.utc_now(), -60)
      to_ts = DateTime.add(DateTime.utc_now(), 60)

      GenServer.cast(channel_pid, {:handle_fetch, from_ts, to_ts, response_topic, correlation_id})
      Process.sleep(200)

      history_msgs = collect_published_messages()

      # Should have 3 entries: 2 buffered while stopped + 1 full on start
      assert length(history_msgs) == 3

      # Check seq numbers are sequential (1, 2, 3)
      seqs = Enum.map(history_msgs, fn {_topic, data, _opts} -> hd(data["entries"] || [])["seq"] end)
      assert seqs == [1, 2, 3]

      # Last message has complete: true
      {_topic, last_data, _opts} = List.last(history_msgs)
      assert last_data["complete"] == true
    end

    test "history messages are rate-limited by history_rate" do
      id = "channel_fetch_rate_test"
      start_supervised!({MockConnection, {id, self()}})

      initial_data = %{plan: 1, plans: %{1 => %{}, 2 => %{}}}
      start_supervised!({RSMP.Service.TLC, {id, "tlc", initial_data}})

      config = %RSMP.Channel.Config{
        code: "tlc.groups",
        channel_name: "live",
        attributes: %{
          "signalgroupstatus" => :on_change,
          "cyclecounter" => :send_along
        },
        update_rate: nil,
        delta_rate: :on_change,
        min_interval: 0,
        default_on: false,
        qos: 0,
        replay_rate: nil,
        history_rate: 2
      }

      {:ok, channel_pid} = RSMP.Channel.start_link({id, config})

      assert_receive {:published, _, _, _}  # channel state

      :ok = RSMP.Channel.start_channel(channel_pid)
      assert_receive {:published, _, _, _}  # full update
      assert_receive {:published, _, _, _}  # channel state

      # Report 4 changes to build buffer
      for i <- 1..4 do
        RSMP.Channel.report(channel_pid, %{"signalgroupstatus" => %{"1" => "G#{i}"}, "cyclecounter" => i})
        Process.sleep(5)
      end

      for _ <- 1..4 do
        assert_receive {:published, _, _, _}, 500
      end

      drain_published_messages()

      # Fetch with history_rate: 2
      response_topic = "supervisor1/history/tlc.groups/live"
      correlation_id = "fetch-rate-123"
      from_ts = DateTime.add(DateTime.utc_now(), -60)
      to_ts = DateTime.add(DateTime.utc_now(), 60)

      GenServer.cast(channel_pid, {:handle_fetch, from_ts, to_ts, response_topic, correlation_id})

      # Collect history messages one by one, allowing 1s per message.
      # With history_rate: 2 (500ms between), 1s per message is generous.
      # Buffer has 5 entries (1 full + 4 deltas).
      history_msgs =
        Enum.reduce_while(1..10, [], fn _i, acc ->
          receive do
            {:published, topic, data, opts} ->
              msg = {topic, data, opts}
              if data["complete"] == true do
                {:halt, acc ++ [msg]}
              else
                {:cont, acc ++ [msg]}
              end
          after
            2000 -> {:halt, acc}
          end
        end)

      assert length(history_msgs) >= 4

      # Last message has complete: true
      {_topic, last_data, _opts} = List.last(history_msgs)
      assert last_data["complete"] == true
    end
  end

  defp collect_published_messages do
    collect_published_messages([])
  end

  defp collect_published_messages(acc) do
    receive do
      {:published, topic, data, opts} ->
        collect_published_messages(acc ++ [{topic, data, opts}])
    after
      0 -> acc
    end
  end

  describe "Aggregation channel" do
    test "get_last_full returns nil before publish, then aggregated sum after force_full" do
      id = "channel_agg_last_full_#{System.unique_integer([:positive])}"
      start_supervised!({MockConnection, {id, self()}})

      config = %RSMP.Channel.Config{
        code: "traffic.volume",
        channel_name: "5s",
        attributes: %{
          "cars" => :on_change,
          "bicycles" => :on_change,
          "busses" => :on_change
        },
        update_rate: 60_000,
        delta_rate: :off,
        aggregation: :sum,
        min_interval: 0,
        default_on: false,
        qos: 0
      }

      {:ok, channel_pid} = RSMP.Channel.start_link({id, config})

      # Drain initial stopped state message
      assert_receive {:published, _, %{"state" => "stopped"}, _}
      assert RSMP.Channel.get_last_full(channel_pid) == nil

      RSMP.Channel.start_channel(channel_pid)
      assert_receive {:published, _, %{"state" => "running"}, _}

      # No publish yet for aggregation channels on start
      assert RSMP.Channel.get_last_full(channel_pid) == nil

      # Report multiple detection events (each carrying only one vehicle type)
      RSMP.Channel.report(channel_pid, %{"cars" => 5})
      RSMP.Channel.report(channel_pid, %{"busses" => 3})
      RSMP.Channel.report(channel_pid, %{"cars" => 2})

      # Still nil — accumulator not flushed yet
      assert RSMP.Channel.get_last_full(channel_pid) == nil

      # Force publish the aggregated window
      RSMP.Channel.force_full(channel_pid)

      assert_receive {:published, topic, data, _opts}
      assert to_string(topic) =~ "traffic.volume/5s"
      entry = hd(data["entries"])
      assert entry["values"]["cars"] == 7
      assert entry["values"]["busses"] == 3
      assert entry["values"]["bicycles"] == 0

      # get_last_full now returns the published aggregated values
      last_full = RSMP.Channel.get_last_full(channel_pid)
      assert last_full["cars"] == 7
      assert last_full["busses"] == 3
      assert last_full["bicycles"] == 0

      # Accumulator resets after publish; next window starts empty
      RSMP.Channel.force_full(channel_pid)
      assert_receive {:published, _topic, data2, _opts}
      assert hd(data2["entries"])["values"] == %{"cars" => 0, "bicycles" => 0, "busses" => 0}

      last_full2 = RSMP.Channel.get_last_full(channel_pid)
      assert last_full2["cars"] == 0
      assert last_full2["bicycles"] == 0
      assert last_full2["busses"] == 0
    end
  end
end
