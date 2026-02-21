defmodule RSMP.StreamTest do
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

  describe "Stream lifecycle" do
    test "stream starts and stops" do
      id = "stream_lifecycle_test"
      start_supervised!({MockConnection, {id, self()}})

      # Start a TLC service so the stream can fetch initial values
      initial_data = %{plan: 1, plans: %{1 => %{}, 2 => %{}}}
      start_supervised!({RSMP.Service.TLC, {id, [], "tlc", initial_data}})

      config = %RSMP.Stream.Config{
        code: "plan",
        stream_name: nil,
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

      {:ok, stream_pid} = RSMP.Stream.start_link({id, "tlc", config})

      assert_receive {:published, topic, state_data, state_options}
      assert to_string(topic) == "#{id}/channel/tlc.plan/default"
      assert state_data == %{"state" => "stopped"}
      assert state_options.retain == true
      assert state_options.qos == 1

      # Stream should not be running
      info = RSMP.Stream.info(stream_pid)
      assert info.running == false
      assert info.seq == 0

      # Start the stream
      assert :ok = RSMP.Stream.start_stream(stream_pid)

      # Should have published a full update
      assert_receive {:published, topic, data, options}
      assert to_string(topic) == "#{id}/status/tlc.plan"
      assert data["values"]["status"] == 1
      assert data["seq"] == 1
      refute Map.has_key?(data, "type")
      assert options.retain == true

      assert_receive {:published, topic, state_data, state_options}
      assert to_string(topic) == "#{id}/channel/tlc.plan/default"
      assert state_data == %{"state" => "running"}
      assert state_options.retain == true
      assert state_options.qos == 1

      # Starting again should fail
      assert {:error, :already_running} = RSMP.Stream.start_stream(stream_pid)

      info = RSMP.Stream.info(stream_pid)
      assert info.running == true
      assert info.seq == 1

      # Stop the stream
      assert :ok = RSMP.Stream.stop_stream(stream_pid)

      # Should publish empty retained message to clear
      assert_receive {:published, _topic, nil, %{retain: true}}

      assert_receive {:published, topic, state_data, state_options}
      assert to_string(topic) == "#{id}/channel/tlc.plan/default"
      assert state_data == %{"state" => "stopped"}
      assert state_options.retain == true
      assert state_options.qos == 1

      info = RSMP.Stream.info(stream_pid)
      assert info.running == false
      assert info.seq == 1

      # Start again, seq should continue instead of resetting
      assert :ok = RSMP.Stream.start_stream(stream_pid)

      assert_receive {:published, _topic, data, _options}
      assert data["values"]["status"] == 1
      assert data["seq"] == 2

      assert_receive {:published, topic, state_data, state_options}
      assert to_string(topic) == "#{id}/channel/tlc.plan/default"
      assert state_data == %{"state" => "running"}
      assert state_options.retain == true
      assert state_options.qos == 1

      info = RSMP.Stream.info(stream_pid)
      assert info.running == true
      assert info.seq == 2

      # Stopping again should fail
      assert :ok = RSMP.Stream.stop_stream(stream_pid)
      assert_receive {:published, _topic, nil, %{retain: true}}

      assert_receive {:published, topic, state_data, state_options}
      assert to_string(topic) == "#{id}/channel/tlc.plan/default"
      assert state_data == %{"state" => "stopped"}
      assert state_options.retain == true
      assert state_options.qos == 1

      assert {:error, :not_running} = RSMP.Stream.stop_stream(stream_pid)
    end

    test "stream with default_on starts automatically" do
      id = "stream_default_on_test"
      start_supervised!({MockConnection, {id, self()}})

      initial_data = %{plan: 2, plans: %{1 => %{}, 2 => %{}}}
      start_supervised!({RSMP.Service.TLC, {id, [], "tlc", initial_data}})

      config = %RSMP.Stream.Config{
        code: "plan",
        stream_name: nil,
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

      {:ok, _stream_pid} = RSMP.Stream.start_link({id, "tlc", config})

      # Should auto-start and publish a full update
      assert_receive {:published, _topic, data, _options}, 500
      assert data["values"]["status"] == 2

      assert_receive {:published, topic, state_data, state_options}, 500
      assert to_string(topic) == "#{id}/channel/tlc.plan/default"
      assert state_data == %{"state" => "running"}
      assert state_options.retain == true
      assert state_options.qos == 1
    end
  end

  describe "Send on Change / Send Along" do
    test "on_change attributes trigger delta, send_along attributes are included" do
      id = "stream_change_test"
      start_supervised!({MockConnection, {id, self()}})

      initial_data = %{plan: 1, plans: %{1 => %{}, 2 => %{}}}
      start_supervised!({RSMP.Service.TLC, {id, [], "tlc", initial_data}})

      config = %RSMP.Stream.Config{
        code: "groups",
        stream_name: "live",
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

      {:ok, stream_pid} = RSMP.Stream.start_link({id, "tlc", config})

      assert_receive {:published, topic, state_data, state_options}
      assert to_string(topic) == "#{id}/channel/tlc.groups/live"
      assert state_data == %{"state" => "stopped"}
      assert state_options.retain == true
      assert state_options.qos == 1

      :ok = RSMP.Stream.start_stream(stream_pid)

      # Consume the initial full update
      assert_receive {:published, _topic, %{"values" => _}, _options}
      assert_receive {:published, _topic, %{"state" => "running"}, _options}

      # Report values where an on_change attr changes
      RSMP.Stream.report(stream_pid, %{
        "signalgroupstatus" => %{"1" => "G", "2" => "G", "3" => "G", "4" => "R", "5" => "R"},
        "stage" => 1,
        "cyclecounter" => 42
      })

      # Should get a delta with the changed on_change attrs + send_along attrs
      assert_receive {:published, topic, data, options}, 500
      assert to_string(topic) =~ "tlc.groups/live"
      assert data["values"]["signalgroupstatus"] == %{"1" => "G", "2" => "G", "3" => "G", "4" => "R", "5" => "R"}
      assert data["values"]["stage"] == 1
      assert data["values"]["cyclecounter"] == 42
      refute Map.has_key?(data, "type")
      assert options.retain == false

      # Report only cyclecounter change (send_along) - should NOT trigger delta
      RSMP.Stream.report(stream_pid, %{
        "signalgroupstatus" => %{"1" => "G", "2" => "G", "3" => "G", "4" => "R", "5" => "R"},
        "stage" => 1,
        "cyclecounter" => 43
      })

      # No delta should be published (cyclecounter is send_along, not a trigger)
      refute_receive {:published, _, %{"values" => _}, %{retain: false}}, 200

      # Report signalgroupstatus change - should trigger delta with updated cyclecounter
      RSMP.Stream.report(stream_pid, %{
        "signalgroupstatus" => %{"4" => "G"},
        "stage" => 1,
        "cyclecounter" => 44
      })

      assert_receive {:published, _topic, data, _options}, 500
      assert data["values"]["signalgroupstatus"] == %{"4" => "G"}
      # cyclecounter should be the latest value, sent along
      assert data["values"]["cyclecounter"] == 44
      # stage didn't change so it should NOT be in the delta
      refute Map.has_key?(data["values"], "stage")
    end
  end

  describe "Stream topic formatting" do
    test "topic includes stream name when present" do
      topic = RSMP.Topic.new("site1", "status", "tlc", "groups", "live", [])
      assert to_string(topic) == "site1/status/tlc.groups/live"
    end

    test "topic omits stream name when nil" do
      topic = RSMP.Topic.new("site1", "status", "tlc", "plan", nil, [])
      assert to_string(topic) == "site1/status/tlc.plan"
    end

    test "topic includes stream name and component" do
      topic = RSMP.Topic.new("site1", "status", "tlc", "traffic", "hourly", ["dl", "1"])
      assert to_string(topic) == "site1/status/tlc.traffic/hourly/dl/1"
    end
  end

  describe "TLC stream definitions" do
    test "TLC node starts with expected stream configs" do
      id = "stream_tlc_test"

      # Start MockConnection before the node
      start_supervised!({MockConnection, {id, self()}})

      # Start TLC node without its own connection (use nil to skip connection)
      {:ok, _} = RSMP.Node.TLC.start_link(id, connection_module: nil)

      # Wait for streams to be started
      Process.sleep(200)

      streams = RSMP.Node.TLC.get_streams(id)
      assert length(streams) == 5

      # Find specific streams
      groups_live = Enum.find(streams, &(&1.code == "groups" and &1.stream_name == "live"))
      plan_stream = Enum.find(streams, &(&1.code == "plan"))
      plans_stream = Enum.find(streams, &(&1.code == "plans"))
      traffic_live = Enum.find(streams, &(&1.module == "traffic" and &1.code == "volume" and &1.stream_name == "live"))
      traffic_5s = Enum.find(streams, &(&1.module == "traffic" and &1.code == "volume" and &1.stream_name == "5s"))

      assert groups_live != nil
      assert groups_live.running == false  # default_on: false
      assert groups_live.qos == 0

      assert plan_stream != nil
      assert plan_stream.running == true  # default_on: true
      assert plan_stream.stream_name == nil

      assert plans_stream != nil
      assert plans_stream.running == true  # default_on: true

      assert traffic_live != nil
      assert traffic_live.running == true
      assert traffic_live.delta_rate == :on_change

      assert traffic_5s != nil
      assert traffic_5s.running == true
      assert traffic_5s.delta_rate == :off
    end

    test "stopped tlc.plan stream does not publish on plan switch" do
      id = "stream_plan_stop_test"

      start_supervised!({MockConnection, {id, self()}})
      {:ok, _} = RSMP.Node.TLC.start_link(id, connection_module: nil)

      Process.sleep(200)

      # Drain startup publications (full updates from default-on streams)
      drain_published_messages()

      assert :ok = RSMP.Node.TLC.stop_stream(id, "tlc", "plan", nil)

      # Stream stop publishes retained nil to clear stale data
      assert_receive {:published, topic, nil, _options}, 500
      assert to_string(topic) == "#{id}/status/tlc.plan"

      # Changing plan should not publish status while stream is stopped
      assert %{status: "ok", plan: 2} = RSMP.Node.TLC.set_plan(id, 2)

      refute_receive {:published, %RSMP.Topic{type: "status", path: %RSMP.Path{module: "tlc", code: "plan"}}, _data, _options}, 400
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
      id = "stream_fetch_test"
      start_supervised!({MockConnection, {id, self()}})

      initial_data = %{plan: 1, plans: %{1 => %{}, 2 => %{}}}
      start_supervised!({RSMP.Service.TLC, {id, [], "tlc", initial_data}})

      config = %RSMP.Stream.Config{
        code: "plan",
        stream_name: nil,
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

      {:ok, stream_pid} = RSMP.Stream.start_link({id, "tlc", config})

      # Receive and discard channel state
      assert_receive {:published, _, _, _}

      # Start and get initial full update + channel state
      :ok = RSMP.Stream.start_stream(stream_pid)
      assert_receive {:published, _, _, _}  # full update
      assert_receive {:published, _, _, _}  # channel state

      drain_published_messages()

      # Now issue a fetch for the full time range
      response_topic = "supervisor1/history/tlc.plan"
      correlation_id = "fetch-test-123"
      from_ts = DateTime.add(DateTime.utc_now(), -60)
      to_ts = DateTime.add(DateTime.utc_now(), 60)

      GenServer.cast(stream_pid, {:handle_fetch, from_ts, to_ts, response_topic, correlation_id})

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
      id = "stream_fetch_empty_test"
      start_supervised!({MockConnection, {id, self()}})

      initial_data = %{plan: 1, plans: %{1 => %{}, 2 => %{}}}
      start_supervised!({RSMP.Service.TLC, {id, [], "tlc", initial_data}})

      config = %RSMP.Stream.Config{
        code: "plan",
        stream_name: nil,
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

      {:ok, stream_pid} = RSMP.Stream.start_link({id, "tlc", config})

      # Just receive the initial channel state
      assert_receive {:published, _, _, _}

      drain_published_messages()

      # Fetch with a future time range that won't match anything
      response_topic = "supervisor1/history/tlc.plan"
      correlation_id = "fetch-empty-123"
      from_ts = DateTime.add(DateTime.utc_now(), 3600)
      to_ts = DateTime.add(DateTime.utc_now(), 7200)

      GenServer.cast(stream_pid, {:handle_fetch, from_ts, to_ts, response_topic, correlation_id})

      # Should get a single complete: true response
      assert_receive {:published, topic, data, _opts}, 500
      assert to_string(topic) == response_topic
      assert data == %{"complete" => true}
    end

    test "reports while stopped are buffered with seq but not published" do
      id = "stream_buffer_stopped_test"
      start_supervised!({MockConnection, {id, self()}})

      initial_data = %{plan: 1, plans: %{1 => %{}, 2 => %{}}}
      start_supervised!({RSMP.Service.TLC, {id, [], "tlc", initial_data}})

      config = %RSMP.Stream.Config{
        code: "groups",
        stream_name: "live",
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

      {:ok, stream_pid} = RSMP.Stream.start_link({id, "tlc", config})
      assert_receive {:published, _, _, _}  # channel state

      # Stream is stopped — reports should buffer but not publish
      RSMP.Stream.report(stream_pid, %{"signalgroupstatus" => %{"1" => "G1"}, "cyclecounter" => 1})
      Process.sleep(10)
      RSMP.Stream.report(stream_pid, %{"signalgroupstatus" => %{"1" => "G2"}, "cyclecounter" => 2})
      Process.sleep(10)

      # No status messages should be published while stopped
      refute_receive {:published, _, _, _}, 100

      # Now start the stream — it publishes a full update
      :ok = RSMP.Stream.start_stream(stream_pid)
      assert_receive {:published, _, _, _}  # full update
      assert_receive {:published, _, _, _}  # channel state

      drain_published_messages()

      # Fetch the buffer — should contain the 2 buffered entries + 1 full = 3
      response_topic = "supervisor1/history/tlc.groups/live"
      correlation_id = "fetch-buffered-123"
      from_ts = DateTime.add(DateTime.utc_now(), -60)
      to_ts = DateTime.add(DateTime.utc_now(), 60)

      GenServer.cast(stream_pid, {:handle_fetch, from_ts, to_ts, response_topic, correlation_id})
      Process.sleep(200)

      history_msgs = collect_published_messages()

      # Should have 3 entries: 2 buffered while stopped + 1 full on start
      assert length(history_msgs) == 3

      # Check seq numbers are sequential (1, 2, 3)
      seqs = Enum.map(history_msgs, fn {_topic, data, _opts} -> data["seq"] end)
      assert seqs == [1, 2, 3]

      # Last message has complete: true
      {_topic, last_data, _opts} = List.last(history_msgs)
      assert last_data["complete"] == true
    end

    test "history messages are rate-limited by history_rate" do
      id = "stream_fetch_rate_test"
      start_supervised!({MockConnection, {id, self()}})

      initial_data = %{plan: 1, plans: %{1 => %{}, 2 => %{}}}
      start_supervised!({RSMP.Service.TLC, {id, [], "tlc", initial_data}})

      config = %RSMP.Stream.Config{
        code: "groups",
        stream_name: "live",
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

      {:ok, stream_pid} = RSMP.Stream.start_link({id, "tlc", config})

      assert_receive {:published, _, _, _}  # channel state

      :ok = RSMP.Stream.start_stream(stream_pid)
      assert_receive {:published, _, _, _}  # full update
      assert_receive {:published, _, _, _}  # channel state

      # Report 4 changes to build buffer
      for i <- 1..4 do
        RSMP.Stream.report(stream_pid, %{"signalgroupstatus" => %{"1" => "G#{i}"}, "cyclecounter" => i})
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

      GenServer.cast(stream_pid, {:handle_fetch, from_ts, to_ts, response_topic, correlation_id})

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
end
