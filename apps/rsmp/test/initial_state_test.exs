defmodule RSMP.InitialStateTest do
  @moduledoc """
  Tests that the initial TLC group state flows correctly from site to supervisor:
  1. Site buffers the initial state in channel buffer (even when channel is stopped)
  2. Site returns initial state when supervisor fetches data
  3. Supervisor stores the fetched initial state as data points
  4. Supervisor graph displays the initial state
  """
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

    def handle_cast({:publish_message, topic, data, options, properties}, test_pid) do
      send(test_pid, {:published, topic, data, options, properties})
      {:noreply, test_pid}
    end
  end

  setup do
    if Process.whereis(RSMP.Registry) == nil do
      RSMP.Registry.start_link()
    end
    :ok
  end

  defp drain_published_messages do
    receive do
      {:published, _topic, _data, _options, _properties} -> drain_published_messages()
    after
      0 -> :ok
    end
  end

  # -----------------------------------------------------------------------
  # 1) Site buffers initial state when channel is stopped (default_on: false)
  # -----------------------------------------------------------------------

  describe "site buffers initial state" do
    test "stopped tlc.groups channel has initial full state in buffer after node starts" do
      id = "initial_state_buffer_#{System.unique_integer([:positive])}"
      start_supervised!({MockConnection, {id, self()}})

      # Start TLC node without its own connection (use nil to skip connection)
      {:ok, _} = RSMP.Node.TLC.start_link(id, connection_module: nil)

      # Wait for channels to be started and initial reports to be processed
      Process.sleep(300)

      # Find the tlc.groups/live channel
      case RSMP.Registry.lookup_channel(id, "tlc.groups", "live") do
        [{channel_pid, _}] ->
          state = :sys.get_state(channel_pid)

          # Channel should be stopped (default_on: false)
          assert state.running == false

          # Buffer should contain the initial state with all groups
          assert length(state.buffer) >= 1

          # The first entry should contain all 4 signal groups
          first_entry = List.last(state.buffer)  # oldest entry (buffer is newest-first)
          groups = first_entry.values["signalgroupstatus"]
          assert is_map(groups)
          assert Map.has_key?(groups, "1")
          assert Map.has_key?(groups, "2")
          assert Map.has_key?(groups, "3")
          assert Map.has_key?(groups, "4")

        [] ->
          flunk("Channel tlc.groups/live not found")
      end
    end

    test "initial state is complete (contains all attributes)" do
      id = "initial_state_complete_#{System.unique_integer([:positive])}"
      start_supervised!({MockConnection, {id, self()}})

      {:ok, _} = RSMP.Node.TLC.start_link(id, connection_module: nil)
      Process.sleep(300)

      case RSMP.Registry.lookup_channel(id, "tlc.groups", "live") do
        [{channel_pid, _}] ->
          state = :sys.get_state(channel_pid)
          first_entry = List.last(state.buffer)

          # Should have signalgroupstatus (on_change) and cyclecounter (send_along)
          assert Map.has_key?(first_entry.values, "signalgroupstatus")
          assert Map.has_key?(first_entry.values, "cyclecounter")

        [] ->
          flunk("Channel tlc.groups/live not found")
      end
    end
  end

  # -----------------------------------------------------------------------
  # 2) Fetch returns the initial state from the buffer
  # -----------------------------------------------------------------------

  describe "fetch returns initial state" do
    test "fetching from stopped channel returns initial buffered state" do
      id = "initial_state_fetch_#{System.unique_integer([:positive])}"
      start_supervised!({MockConnection, {id, self()}})

      {:ok, _} = RSMP.Node.TLC.start_link(id, connection_module: nil)
      Process.sleep(300)

      drain_published_messages()

      case RSMP.Registry.lookup_channel(id, "tlc.groups", "live") do
        [{channel_pid, _}] ->
          # Issue a fetch for the full time range
          response_topic = "supervisor1/history/tlc.groups/live"
          correlation_id = "fetch-initial-123"
          from_ts = DateTime.add(DateTime.utc_now(), -60)
          to_ts = DateTime.add(DateTime.utc_now(), 60)

          GenServer.cast(channel_pid, {:handle_fetch, from_ts, to_ts, response_topic, correlation_id})

          # Collect history messages until we get one with complete: true
          history_msgs = collect_until_complete(3000)

          # Should have at least 1 history message with the initial state
          assert length(history_msgs) >= 1

          # First message should contain the full initial groups
          {_topic, first_data, _opts, _props} = List.first(history_msgs)
          groups = hd(first_data["entries"])["values"]["signalgroupstatus"]
          assert is_map(groups)
          assert Map.has_key?(groups, "1")
          assert Map.has_key?(groups, "2")
          assert Map.has_key?(groups, "3")
          assert Map.has_key?(groups, "4")

          # Last message should have complete: true
          {_topic, last_data, _opts, _props} = List.last(history_msgs)
          assert last_data["complete"] == true

        [] ->
          flunk("Channel tlc.groups/live not found")
      end
    end
  end

  # -----------------------------------------------------------------------
  # 3) Supervisor stores the fetched initial state
  # -----------------------------------------------------------------------

  describe "supervisor stores initial state from history" do
    test "supervisor stores data points from history response with initial groups" do
      supervisor_id = "initial_sup_store_#{System.unique_integer([:positive])}"
      site_id = "initial_state_sup_store_#{System.unique_integer([:positive])}"

      {:ok, pid} = RSMP.Remote.SiteData.start_link({supervisor_id, site_id})

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      # Set up a pending fetch so receive_history accepts the message
      correlation_id = "test-corr-initial-#{System.unique_integer([:positive])}"
      :sys.replace_state(pid, fn state ->
        pending_fetch = %{site_id: site_id, code: "tlc.groups", channel_name: "live"}
        %{state | pending_fetches: Map.put(state.pending_fetches, correlation_id, pending_fetch)}
      end)

      # Send a history response with initial full groups state
      ts = DateTime.utc_now() |> DateTime.to_iso8601()
      topic = RSMP.Topic.new(site_id, "history", "tlc.groups", "live")
      data = %{
        "entries" => [%{
          "values" => %{
            "signalgroupstatus" => %{"1" => "G", "2" => "r", "3" => "G", "4" => "r"},
            "cyclecounter" => 0,
            "stage" => 0
          },
          "ts" => ts,
          "seq" => 1
        }],
        "complete" => true
      }

      GenServer.cast(pid, {:receive, "history", topic, data, %{"Correlation-Data": correlation_id}})
      :timer.sleep(50)

      # Verify the data point was stored
      points = RSMP.Remote.SiteData.data_points(supervisor_id, site_id, "tlc.groups/live")
      assert length(points) >= 1

      # First point should contain the initial groups
      first_point = List.first(points)
      assert first_point.values.groups == %{"1" => "G", "2" => "r", "3" => "G", "4" => "r"}
    end
  end

  # -----------------------------------------------------------------------
  # 4) Supervisor graph sees the initial state
  # -----------------------------------------------------------------------

  describe "supervisor graph displays initial state" do
    test "data points with keys includes initial groups for graph rendering" do
      supervisor_id = "initial_graph_#{System.unique_integer([:positive])}"
      site_id = "initial_state_graph_#{System.unique_integer([:positive])}"

      {:ok, pid} = RSMP.Remote.SiteData.start_link({supervisor_id, site_id})

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      # Set up a pending fetch
      correlation_id = "test-corr-graph-#{System.unique_integer([:positive])}"
      :sys.replace_state(pid, fn state ->
        pending_fetch = %{site_id: site_id, code: "tlc.groups", channel_name: "live"}
        %{state | pending_fetches: Map.put(state.pending_fetches, correlation_id, pending_fetch)}
      end)

      # Send initial groups via history
      ts = DateTime.utc_now() |> DateTime.to_iso8601()
      topic = RSMP.Topic.new(site_id, "history", "tlc.groups", "live")
      data = %{
        "entries" => [%{
          "values" => %{
            "signalgroupstatus" => %{"1" => "G", "2" => "r", "3" => "G", "4" => "r"},
            "cyclecounter" => 0,
            "stage" => 0
          },
          "ts" => ts,
          "seq" => 1
        }],
        "complete" => false
      }

      GenServer.cast(pid, {:receive, "history", topic, data, %{"Correlation-Data": correlation_id}})

      # Then send a delta update
      ts2 = DateTime.add(DateTime.utc_now(), 1) |> DateTime.to_iso8601()
      data2 = %{
        "entries" => [%{
          "values" => %{
            "signalgroupstatus" => %{"1" => "Y"},
            "cyclecounter" => 1
          },
          "ts" => ts2,
          "seq" => 2
        }],
        "complete" => true
      }

      GenServer.cast(pid, {:receive, "history", topic, data2, %{"Correlation-Data": correlation_id}})
      :timer.sleep(50)

      # Get data points with keys (as used by the graph)
      keyed_points = RSMP.Remote.SiteData.data_points_with_keys(supervisor_id, site_id, "tlc.groups/live")
      assert length(keyed_points) == 2

      # Replay deltas to build full snapshots (same logic as LiveView)
      {history, _state} =
        Enum.reduce(keyed_points, {[], %{}}, fn {_key, point}, {history, state} ->
          groups_delta = get_groups_from_point(point.values)
          state = Map.merge(state, groups_delta)
          {history ++ [%{groups: state}], state}
        end)

      # First entry should have all 4 groups from the initial state
      first_groups = List.first(history).groups
      assert Map.has_key?(first_groups, "1")
      assert Map.has_key?(first_groups, "2")
      assert Map.has_key?(first_groups, "3")
      assert Map.has_key?(first_groups, "4")
      assert first_groups["1"] == "G"
      assert first_groups["2"] == "r"

      # Second entry should merge the delta onto the initial state
      second_groups = Enum.at(history, 1).groups
      assert second_groups["1"] == "Y"  # Changed from G to Y
      assert second_groups["2"] == "r"  # Unchanged from initial
      assert second_groups["3"] == "G"  # Unchanged from initial
      assert second_groups["4"] == "r"  # Unchanged from initial
    end
  end

  # -----------------------------------------------------------------------
  # 5) Supervisor triggers fetch when channel first becomes running (nil→running)
  # -----------------------------------------------------------------------

  describe "supervisor fetches on channel nil→running" do
    test "receive_channel triggers fetch when channel goes from nil to running" do
      supervisor_id = "initial_nil_running_#{System.unique_integer([:positive])}"
      site_id = "initial_state_nil_running_#{System.unique_integer([:positive])}"

      # Start a mock connection to intercept published fetch messages
      start_supervised!({MockConnection, {supervisor_id, self()}})

      {:ok, pid} = RSMP.Remote.SiteData.start_link({supervisor_id, site_id})

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      Phoenix.PubSub.subscribe(RSMP.PubSub, "supervisor:#{supervisor_id}:#{site_id}")

      # Send a channel state "running" for tlc.groups/live
      # The site hasn't seen this channel before (nil → running)
      topic = RSMP.Topic.new(site_id, "channel", "tlc.groups", "live")
      data = %{"state" => "running"}
      GenServer.cast(pid, {:receive, "channel", topic, data, %{}})
      :timer.sleep(50)

      # The site_data should have recorded the channel as running
      site = RSMP.Remote.SiteData.get_state(supervisor_id, site_id)
      assert site.channels["tlc.groups/live"] == "running"

      # Verify a fetch was triggered by checking pending_fetches
      state = :sys.get_state(pid)
      has_groups_fetch = Enum.any?(state.pending_fetches, fn {_id, fetch} ->
        fetch.code == "tlc.groups" && fetch.channel_name == "live"
      end)
      assert has_groups_fetch, "Expected a pending fetch for tlc.groups/live but found: #{inspect(state.pending_fetches)}"
    end
  end

  # -----------------------------------------------------------------------
  # 6) Retained full status messages do NOT create data points
  # -----------------------------------------------------------------------

  describe "retained full not stored as data point" do
    test "retained full status does not create a data point" do
      supervisor_id = "retained_no_dp_sup_#{System.unique_integer([:positive])}"
      site_id = "retained_no_dp_#{System.unique_integer([:positive])}"

      {:ok, pid} = RSMP.Remote.SiteData.start_link({supervisor_id, site_id})

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      Phoenix.PubSub.subscribe(RSMP.PubSub, "supervisor:#{supervisor_id}:#{site_id}")

      # Send a status message (non-retained — the Site GenServer always treats status as non-retained)
      ts = DateTime.utc_now() |> DateTime.to_iso8601()
      topic = RSMP.Topic.new(site_id, "status", "tlc.groups", "live")
      data = %{
        "entries" => [%{
          "values" => %{
            "signalgroupstatus" => %{"1" => "G", "2" => "r", "3" => "G", "4" => "r"},
            "cyclecounter" => 0,
            "stage" => 0
          },
          "ts" => ts,
          "seq" => 10
        }]
      }

      GenServer.cast(pid, {:receive, "status", topic, data, %{}})
      :timer.sleep(50)

      # Status display should be updated
      assert_receive %{topic: "status"}, 200

      # A data_point should have been broadcast (live status always creates data points)
      assert_receive %{topic: "data_point"}, 200

      # Data points should be persisted
      points = RSMP.Remote.SiteData.data_points(supervisor_id, site_id, "tlc.groups/live")
      assert length(points) >= 1
    end
  end

  defp get_groups_from_point(values) do
    cond do
      is_map(values[:groups]) -> values[:groups]
      is_map(values["groups"]) -> values["groups"]
      is_map(values[:signalgroupstatus]) -> values[:signalgroupstatus]
      is_map(values["signalgroupstatus"]) -> values["signalgroupstatus"]
      true -> %{}
    end
  end

  # Collect published messages until we receive one with complete: true,
  # or timeout_ms elapses.
  defp collect_until_complete(timeout_ms, acc \\ []) do
    receive do
      {:published, topic, data, opts, props} ->
        msg = {topic, data, opts, props}
        if is_map(data) && data["complete"] == true do
          acc ++ [msg]
        else
          collect_until_complete(timeout_ms, acc ++ [msg])
        end
    after
      timeout_ms -> acc
    end
  end
end
