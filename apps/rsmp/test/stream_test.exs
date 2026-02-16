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

      # Stream should not be running
      info = RSMP.Stream.info(stream_pid)
      assert info.running == false
      assert info.seq == 0

      # Start the stream
      assert :ok = RSMP.Stream.start_stream(stream_pid)

      # Should have published a full update
      assert_receive {:published, topic, data, options}
      assert to_string(topic) == "#{id}/status/tlc.plan"
      assert data["type"] == "full"
      assert data["seq"] == 1
      assert data["data"]["status"] == 1
      assert options.retain == true

      # Starting again should fail
      assert {:error, :already_running} = RSMP.Stream.start_stream(stream_pid)

      info = RSMP.Stream.info(stream_pid)
      assert info.running == true
      assert info.seq == 1

      # Stop the stream
      assert :ok = RSMP.Stream.stop_stream(stream_pid)

      # Should publish empty retained message to clear
      assert_receive {:published, _topic, nil, %{retain: true}}

      info = RSMP.Stream.info(stream_pid)
      assert info.running == false
      assert info.seq == 1

      # Start again, seq should continue instead of resetting
      assert :ok = RSMP.Stream.start_stream(stream_pid)

      assert_receive {:published, _topic, data, _options}
      assert data["type"] == "full"
      assert data["seq"] == 2

      info = RSMP.Stream.info(stream_pid)
      assert info.running == true
      assert info.seq == 2

      # Stopping again should fail
      assert :ok = RSMP.Stream.stop_stream(stream_pid)
      assert_receive {:published, _topic, nil, %{retain: true}}

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
      assert data["type"] == "full"
      assert data["data"]["status"] == 2
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
      :ok = RSMP.Stream.start_stream(stream_pid)

      # Consume the initial full update
      assert_receive {:published, _topic, %{"type" => "full"}, _options}

      # Report values where an on_change attr changes
      RSMP.Stream.report(stream_pid, %{
        "signalgroupstatus" => %{"1" => "G", "2" => "G", "3" => "G", "4" => "R", "5" => "R"},
        "stage" => 1,
        "cyclecounter" => 42
      })

      # Should get a delta with the changed on_change attrs + send_along attrs
      assert_receive {:published, topic, data, options}, 500
      assert to_string(topic) =~ "tlc.groups/live"
      assert data["type"] == "delta"
      assert data["data"]["signalgroupstatus"] == %{"1" => "G", "2" => "G", "3" => "G", "4" => "R", "5" => "R"}
      assert data["data"]["stage"] == 1
      assert data["data"]["cyclecounter"] == 42
      assert options.retain == false

      # Report only cyclecounter change (send_along) - should NOT trigger delta
      RSMP.Stream.report(stream_pid, %{
        "signalgroupstatus" => %{"1" => "G", "2" => "G", "3" => "G", "4" => "R", "5" => "R"},
        "stage" => 1,
        "cyclecounter" => 43
      })

      # No delta should be published
      refute_receive {:published, _, %{"type" => "delta"}, _}, 200

      # Report signalgroupstatus change - should trigger delta with updated cyclecounter
      RSMP.Stream.report(stream_pid, %{
        "signalgroupstatus" => %{"4" => "G"},
        "stage" => 1,
        "cyclecounter" => 44
      })

      assert_receive {:published, _topic, data, _options}, 500
      assert data["type"] == "delta"
      assert data["data"]["signalgroupstatus"] == %{"4" => "G"}
      # cyclecounter should be the latest value, sent along
      assert data["data"]["cyclecounter"] == 44
      # stage didn't change so it should NOT be in the delta
      refute Map.has_key?(data["data"], "stage")
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
      assert length(streams) == 3

      # Find specific streams
      groups_live = Enum.find(streams, &(&1.code == "groups" and &1.stream_name == "live"))
      plan_stream = Enum.find(streams, &(&1.code == "plan"))
      plans_stream = Enum.find(streams, &(&1.code == "plans"))

      assert groups_live != nil
      assert groups_live.running == false  # default_on: false
      assert groups_live.qos == 0

      assert plan_stream != nil
      assert plan_stream.running == true  # default_on: true
      assert plan_stream.stream_name == nil

      assert plans_stream != nil
      assert plans_stream.running == true  # default_on: true
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
end
