defmodule RSMP.SupervisorTest do
  use ExUnit.Case

  setup do
    {:ok, supervisor_id} = RSMP.Supervisors.start_supervisor()
    [{pid, _}] = RSMP.Registry.lookup_supervisor(supervisor_id)

    on_exit(fn ->
      RSMP.Supervisors.stop_supervisor(supervisor_id)
    end)

    %{supervisor_id: supervisor_id, pid: pid}
  end

  test "handles EXIT messages without crashing", %{pid: pid} do
    assert pid != nil

    fake_pid = spawn(fn -> :ok end)
    exit_msg = {:EXIT, fake_pid, {:shutdown, :econnrefused}}

    send(pid, exit_msg)

    :timer.sleep(10)

    assert Process.alive?(pid)
  end

  test "keeps previous groups stage when delta omits stage", %{supervisor_id: supervisor_id, pid: pid} do
    assert pid != nil

    site_id = "supervisor_delta_stage_#{System.unique_integer([:positive])}"

    full_payload =
      RSMP.Utility.to_payload(%{
        "type" => "full",
        "data" => %{
          "signalgroupstatus" => "GrGr",
          "stage" => 2,
          "cyclecounter" => 10
        }
      })

    send(pid, {:publish, %{topic: "#{site_id}/status/tlc.groups/live", payload: full_payload, properties: %{}}})
    :timer.sleep(20)

    delta_payload =
      RSMP.Utility.to_payload(%{
        "type" => "delta",
        "data" => %{
          "signalgroupstatus" => "YrYr",
          "cyclecounter" => 11
        }
      })

    send(pid, {:publish, %{topic: "#{site_id}/status/tlc.groups/live", payload: delta_payload, properties: %{}}})
    :timer.sleep(20)

    status = RSMP.Supervisor.site(supervisor_id, site_id).statuses["tlc.groups"]
    assert status.groups == %{"1" => "Y", "2" => "r", "3" => "Y", "4" => "r"}
    assert status.cycle == 11
    assert status.stage == 2
  end

  test "traffic.volume live delta: missing counters imply zero, stale values are cleared", %{supervisor_id: supervisor_id, pid: pid} do
    assert pid != nil

    site_id = "supervisor_traffic_delta_#{System.unique_integer([:positive])}"

    full_payload =
      RSMP.Utility.to_payload(%{
        "type" => "full",
        "data" => %{
          "cars" => 4
        }
      })

    send(pid, {:publish, %{topic: "#{site_id}/status/traffic.volume/live", payload: full_payload, properties: %{}}})
    :timer.sleep(20)

    delta_payload =
      RSMP.Utility.to_payload(%{
        "type" => "delta",
        "data" => %{
          "cars" => 6
        }
      })

    send(pid, {:publish, %{topic: "#{site_id}/status/traffic.volume/live", payload: delta_payload, properties: %{}}})
    :timer.sleep(20)

    status = RSMP.Supervisor.site(supervisor_id, site_id).statuses["traffic.volume"]
    assert status.cars == 6

    # A delta with only bicycles implies cars = 0 (missing key means zero for traffic.volume).
    delta_payload_2 =
      RSMP.Utility.to_payload(%{
        "type" => "delta",
        "data" => %{
          "bicycles" => 2
        }
      })

    send(pid, {:publish, %{topic: "#{site_id}/status/traffic.volume/live", payload: delta_payload_2, properties: %{}}})
    :timer.sleep(20)

    status = RSMP.Supervisor.site(supervisor_id, site_id).statuses["traffic.volume"]
    assert status.bicycles == 2
    assert status.cars == 0
    assert status.busses == 0
  end

  test "traffic.volume 5s channel does not overwrite live display values", %{supervisor_id: supervisor_id, pid: pid} do
    site_id = "supervisor_traffic_5s_isolation_#{System.unique_integer([:positive])}"

    live_payload =
      RSMP.Utility.to_payload(%{
        "type" => "delta",
        "data" => %{"cars" => 3}
      })

    send(pid, {:publish, %{topic: "#{site_id}/status/traffic.volume/live", payload: live_payload, properties: %{}}})
    :timer.sleep(20)

    status = RSMP.Supervisor.site(supervisor_id, site_id).statuses["traffic.volume"]
    assert status.cars == 3

    # 5s aggregated full should not overwrite the display values
    s5_payload =
      RSMP.Utility.to_payload(%{
        "values" => %{"cars" => 99, "bicycles" => 99, "busses" => 99},
        "seq" => 1
      })

    send(pid, {:publish, %{topic: "#{site_id}/status/traffic.volume/5s", retain: true, payload: s5_payload, properties: %{}}})
    :timer.sleep(20)

    status = RSMP.Supervisor.site(supervisor_id, site_id).statuses["traffic.volume"]
    assert status.cars == 3
    assert status.bicycles == 0
    assert status.busses == 0

    # seq for 5s channel should still be tracked
    seq = get_in(status, [:seq]) || get_in(status, ["seq"])
    assert is_map(seq)
    assert Map.get(seq, "5s") == 1
  end

  # ---------------------------------------------------------------------------
  # Replay
  # ---------------------------------------------------------------------------

  test "receive_replay broadcasts data_point with source :replay", %{supervisor_id: supervisor_id, pid: pid} do
    site_id = "supervisor_replay_source_#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(RSMP.PubSub, "supervisor:#{supervisor_id}:#{site_id}")

    payload =
      RSMP.Utility.to_payload(%{
        "values" => %{"cars" => 3, "bicycles" => 1},
        "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "seq" => 1
      })

    send(pid, {:publish, %{topic: "#{site_id}/replay/traffic.volume/live", payload: payload, properties: %{}}})

    assert_receive %{topic: "data_point", source: :replay, path: "traffic.volume", channel: "live"}
  end

  test "receive_replay includes values converted via traffic converter", %{supervisor_id: supervisor_id, pid: pid} do
    site_id = "supervisor_replay_values_#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(RSMP.PubSub, "supervisor:#{supervisor_id}:#{site_id}")

    payload =
      RSMP.Utility.to_payload(%{
        "values" => %{"cars" => 7, "bicycles" => 2, "busses" => 0},
        "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "seq" => 5
      })

    send(pid, {:publish, %{topic: "#{site_id}/replay/traffic.volume/live", payload: payload, properties: %{}}})

    assert_receive %{topic: "data_point", source: :replay, values: values}
    assert values.cars == 7
    assert values.bicycles == 2
  end

  test "receive_replay includes seq and ts from payload", %{supervisor_id: supervisor_id, pid: pid} do
    site_id = "supervisor_replay_seq_#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(RSMP.PubSub, "supervisor:#{supervisor_id}:#{site_id}")
    ts = DateTime.utc_now() |> DateTime.truncate(:second)

    payload =
      RSMP.Utility.to_payload(%{
        "values" => %{"cars" => 1},
        "ts" => ts |> DateTime.to_iso8601(),
        "seq" => 42
      })

    send(pid, {:publish, %{topic: "#{site_id}/replay/traffic.volume/live", payload: payload, properties: %{}}})

    assert_receive %{topic: "data_point", source: :replay, seq: 42, ts: ^ts}
  end

  test "receive_replay broadcasts multiple points preserving order", %{supervisor_id: supervisor_id, pid: pid} do
    site_id = "supervisor_replay_order_#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(RSMP.PubSub, "supervisor:#{supervisor_id}:#{site_id}")

    for seq <- 1..5 do
      payload =
        RSMP.Utility.to_payload(%{
          "values" => %{"cars" => seq},
          "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "seq" => seq
        })

      send(pid, {:publish, %{topic: "#{site_id}/replay/traffic.volume/live", payload: payload, properties: %{}}})
    end

    received =
      for _i <- 1..5 do
        assert_receive %{topic: "data_point", source: :replay, seq: seq}
        seq
      end

    assert received == [1, 2, 3, 4, 5]
  end

  test "receive_replay ignores payload without 'values' key", %{supervisor_id: supervisor_id, pid: pid} do
    site_id = "supervisor_replay_no_vals_#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(RSMP.PubSub, "supervisor:#{supervisor_id}:#{site_id}")

    payload =
      RSMP.Utility.to_payload(%{
        "ts" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

    send(pid, {:publish, %{topic: "#{site_id}/replay/traffic.volume/live", payload: payload, properties: %{}}})

    refute_receive %{topic: "data_point"}, 50
  end

  test "live status data_point has source :live (not :replay)", %{supervisor_id: supervisor_id, pid: pid} do
    site_id = "supervisor_live_source_#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(RSMP.PubSub, "supervisor:#{supervisor_id}:#{site_id}")

    payload =
      RSMP.Utility.to_payload(%{
        "type" => "full",
        "data" => %{"cars" => 2}
      })

    send(pid, {:publish, %{topic: "#{site_id}/status/traffic.volume/live", payload: payload, properties: %{}}})

    assert_receive %{topic: "data_point"} = msg
    assert msg.source == :live
  end

  test "traffic.volume seq is latest channel seq", %{supervisor_id: supervisor_id, pid: pid} do
    assert pid != nil

    site_id = "supervisor_traffic_seq_map_#{System.unique_integer([:positive])}"

    live_full_payload =
      RSMP.Utility.to_payload(%{
        "type" => "full",
        "seq" => 64,
        "data" => %{
          "cars" => 4
        }
      })

    send(pid, {:publish, %{topic: "#{site_id}/status/traffic.volume/live", payload: live_full_payload, properties: %{}}})
    :timer.sleep(20)

    status = RSMP.Supervisor.site(supervisor_id, site_id).statuses["traffic.volume"]
    assert status["seq"] == %{"live" => 64}

    s5_full_payload =
      RSMP.Utility.to_payload(%{
        "type" => "full",
        "seq" => 12,
        "data" => %{
          "cars" => 4,
          "bicycles" => 1
        }
      })

    send(pid, {:publish, %{topic: "#{site_id}/status/traffic.volume/5s", payload: s5_full_payload, properties: %{}}})
    :timer.sleep(20)

    status = RSMP.Supervisor.site(supervisor_id, site_id).statuses["traffic.volume"]
    assert status["seq"] == %{"live" => 64, "5s" => 12}
  end

  # ---------------------------------------------------------------------------
  # Data points storage via supervisor
  # ---------------------------------------------------------------------------

  test "live status stores data points keyed by seq", %{supervisor_id: supervisor_id, pid: pid} do
    site_id = "supervisor_dp_seq_#{System.unique_integer([:positive])}"

    for seq <- 1..5 do
      payload =
        RSMP.Utility.to_payload(%{
          "type" => "full",
          "seq" => seq,
          "data" => %{"cars" => seq}
        })

      send(pid, {:publish, %{topic: "#{site_id}/status/traffic.volume/live", payload: payload, properties: %{}}})
    end

    :timer.sleep(50)

    points = RSMP.Supervisor.data_points(supervisor_id, site_id, "traffic.volume/live")
    assert length(points) == 5
    cars = Enum.map(points, fn %{values: v} -> v.cars end)
    assert cars == [1, 2, 3, 4, 5]
  end

  test "replay stores data points keyed by seq without duplicates", %{supervisor_id: supervisor_id, pid: pid} do
    site_id = "supervisor_dp_replay_dedup_#{System.unique_integer([:positive])}"

    # Send replay seq 1-3
    for seq <- 1..3 do
      payload =
        RSMP.Utility.to_payload(%{
          "values" => %{"cars" => seq},
          "ts" => DateTime.utc_now() |> DateTime.add(-10 + seq) |> DateTime.to_iso8601(),
          "seq" => seq
        })

      send(pid, {:publish, %{topic: "#{site_id}/replay/traffic.volume/live", payload: payload, properties: %{}}})
    end

    :timer.sleep(50)

    points = RSMP.Supervisor.data_points(supervisor_id, site_id, "traffic.volume/live")
    assert length(points) == 3

    # Resend seq 2 with different value — should overwrite, not add
    payload =
      RSMP.Utility.to_payload(%{
        "values" => %{"cars" => 99},
        "ts" => DateTime.utc_now() |> DateTime.add(-8) |> DateTime.to_iso8601(),
        "seq" => 2
      })

    send(pid, {:publish, %{topic: "#{site_id}/replay/traffic.volume/live", payload: payload, properties: %{}}})
    :timer.sleep(50)

    points = RSMP.Supervisor.data_points(supervisor_id, site_id, "traffic.volume/live")
    assert length(points) == 3
    # seq 2 should have updated value
    cars = Enum.map(points, fn %{values: v} -> v.cars end)
    assert 99 in cars
  end

  test "concurrent live and replay data stored correctly", %{supervisor_id: supervisor_id, pid: pid} do
    site_id = "supervisor_dp_concurrent_#{System.unique_integer([:positive])}"
    now = DateTime.utc_now()

    # Send live status (seq 11-13, current timestamps)
    for seq <- 11..13 do
      payload =
        RSMP.Utility.to_payload(%{
          "type" => "full",
          "seq" => seq,
          "data" => %{"cars" => seq}
        })

      send(pid, {:publish, %{topic: "#{site_id}/status/traffic.volume/live", payload: payload, properties: %{}}})
    end

    # Send replay (seq 1-5, historical timestamps)
    for seq <- 1..5 do
      ts = DateTime.add(now, -20 + seq) |> DateTime.to_iso8601()

      payload =
        RSMP.Utility.to_payload(%{
          "values" => %{"cars" => seq},
          "ts" => ts,
          "seq" => seq
        })

      send(pid, {:publish, %{topic: "#{site_id}/replay/traffic.volume/live", payload: payload, properties: %{}}})
    end

    :timer.sleep(100)

    points = RSMP.Supervisor.data_points(supervisor_id, site_id, "traffic.volume/live")
    # 3 live + 5 replay = 8 total (no seq overlap)
    assert length(points) == 8

    # Points should be sorted by ts (replay timestamps are older)
    timestamps = Enum.map(points, fn %{ts: t} -> DateTime.to_unix(t, :microsecond) end)
    assert timestamps == Enum.sort(timestamps)
  end

  test "data points aggregate into bins with correct backfill", %{supervisor_id: supervisor_id, pid: pid} do
    site_id = "supervisor_dp_bins_#{System.unique_integer([:positive])}"
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Send live data for the last 5 seconds
    for i <- 5..1//-1 do
      _ts_offset = -i
      payload =
        RSMP.Utility.to_payload(%{
          "type" => "full",
          "seq" => 100 - i,
          "data" => %{"cars" => 1}
        })

      send(pid, {:publish, %{topic: "#{site_id}/status/traffic.volume/live", payload: payload, properties: %{}}})
    end

    :timer.sleep(50)

    points = RSMP.Supervisor.data_points(supervisor_id, site_id, "traffic.volume/live")
    assert length(points) == 5

    # Aggregate: all 5 points should land in bins near the right edge
    bins = RSMP.Remote.Node.Site.aggregate_into_bins(points, 10, now)
    assert length(bins) == 10

    # Since all points have ts ~= now (live status uses DateTime.utc_now()),
    # they should all be in the rightmost bin
    total_cars = Enum.reduce(bins, 0, fn b, acc -> acc + b.cars end)
    assert total_cars == 5
  end

  # ---------------------------------------------------------------------------
  # Gap detection
  # ---------------------------------------------------------------------------

  test "has_seq_gaps? returns false when no data", %{supervisor_id: supervisor_id} do
    site_id = "supervisor_gaps_empty_#{System.unique_integer([:positive])}"
    assert RSMP.Supervisor.has_seq_gaps?(supervisor_id, site_id, "traffic.volume/live") == false
  end

  test "has_seq_gaps? returns false for contiguous seqs", %{supervisor_id: supervisor_id, pid: pid} do
    site_id = "supervisor_gaps_contiguous_#{System.unique_integer([:positive])}"

    for seq <- 1..5 do
      payload =
        RSMP.Utility.to_payload(%{
          "type" => "full",
          "seq" => seq,
          "data" => %{"cars" => seq}
        })

      send(pid, {:publish, %{topic: "#{site_id}/status/traffic.volume/live", payload: payload, properties: %{}}})
    end

    :timer.sleep(50)
    assert RSMP.Supervisor.has_seq_gaps?(supervisor_id, site_id, "traffic.volume/live") == false
  end

  test "has_seq_gaps? returns true when seqs have gaps", %{supervisor_id: supervisor_id, pid: pid} do
    site_id = "supervisor_gaps_missing_#{System.unique_integer([:positive])}"

    for seq <- [1, 2, 5, 6] do
      payload =
        RSMP.Utility.to_payload(%{
          "type" => "full",
          "seq" => seq,
          "data" => %{"cars" => seq}
        })

      send(pid, {:publish, %{topic: "#{site_id}/status/traffic.volume/live", payload: payload, properties: %{}}})
    end

    :timer.sleep(50)
    assert RSMP.Supervisor.has_seq_gaps?(supervisor_id, site_id, "traffic.volume/live") == true
    gaps = RSMP.Supervisor.seq_gaps(supervisor_id, site_id, "traffic.volume/live")
    assert gaps == [{3, 4}]
  end

  test "seq_gaps returns multiple gap ranges", %{supervisor_id: supervisor_id, pid: pid} do
    site_id = "supervisor_gaps_multi_#{System.unique_integer([:positive])}"

    for seq <- [1, 2, 5, 6, 9, 10] do
      payload =
        RSMP.Utility.to_payload(%{
          "type" => "full",
          "seq" => seq,
          "data" => %{"cars" => seq}
        })

      send(pid, {:publish, %{topic: "#{site_id}/status/traffic.volume/live", payload: payload, properties: %{}}})
    end

    :timer.sleep(50)
    gaps = RSMP.Supervisor.seq_gaps(supervisor_id, site_id, "traffic.volume/live")
    assert gaps == [{3, 4}, {7, 8}]
  end

  # ---------------------------------------------------------------------------
  # History (fetch response)
  # ---------------------------------------------------------------------------

  test "receive_history broadcasts data_point with source :history", %{supervisor_id: supervisor_id, pid: pid} do
    site_id = "supervisor_history_source_#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(RSMP.PubSub, "supervisor:#{supervisor_id}:#{site_id}")

    # First, set up a pending fetch so receive_history accepts the message
    correlation_id = "test-corr-#{System.unique_integer([:positive])}"
    :sys.replace_state(pid, fn state ->
      pending_fetch = %{site_id: site_id, code: "traffic.volume", channel_name: "live"}
      %{state | pending_fetches: Map.put(state.pending_fetches, correlation_id, pending_fetch)}
    end)

    payload =
      RSMP.Utility.to_payload(%{
        "values" => %{"cars" => 3, "bicycles" => 1},
        "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "seq" => 42,
        "complete" => false
      })

    properties = %{"Correlation-Data": correlation_id}
    send(pid, {:publish, %{topic: "#{supervisor_id}/history/traffic.volume/live", payload: payload, properties: properties}})

    assert_receive %{topic: "data_point", source: :history, path: "traffic.volume", channel: "live", seq: 42}
  end

  test "receive_history stores data points by seq", %{supervisor_id: supervisor_id, pid: pid} do
    site_id = "supervisor_history_store_#{System.unique_integer([:positive])}"

    correlation_id = "test-corr-#{System.unique_integer([:positive])}"
    :sys.replace_state(pid, fn state ->
      pending_fetch = %{site_id: site_id, code: "traffic.volume", channel_name: "live"}
      %{state | pending_fetches: Map.put(state.pending_fetches, correlation_id, pending_fetch)}
    end)

    # First put some existing data with gaps (missing seq 3,4)
    for seq <- [1, 2, 5, 6] do
      payload =
        RSMP.Utility.to_payload(%{
          "type" => "full",
          "seq" => seq,
          "data" => %{"cars" => seq}
        })

      send(pid, {:publish, %{topic: "#{site_id}/status/traffic.volume/live", payload: payload, properties: %{}}})
    end

    :timer.sleep(50)
    assert RSMP.Supervisor.has_seq_gaps?(supervisor_id, site_id, "traffic.volume/live") == true

    # Now send history messages to fill the gaps
    for seq <- [3, 4] do
      payload =
        RSMP.Utility.to_payload(%{
          "values" => %{"cars" => seq},
          "ts" => DateTime.utc_now() |> DateTime.add(-10 + seq) |> DateTime.to_iso8601(),
          "seq" => seq,
          "complete" => (seq == 4)
        })

      properties = %{"Correlation-Data": correlation_id}
      send(pid, {:publish, %{topic: "#{supervisor_id}/history/traffic.volume/live", payload: payload, properties: properties}})
    end

    :timer.sleep(50)

    # Gaps should now be filled
    assert RSMP.Supervisor.has_seq_gaps?(supervisor_id, site_id, "traffic.volume/live") == false
    points = RSMP.Supervisor.data_points(supervisor_id, site_id, "traffic.volume/live")
    assert length(points) == 6
  end

  test "receive_history clears pending fetch on complete", %{supervisor_id: supervisor_id, pid: pid} do
    site_id = "supervisor_history_complete_#{System.unique_integer([:positive])}"

    correlation_id = "test-corr-#{System.unique_integer([:positive])}"
    :sys.replace_state(pid, fn state ->
      pending_fetch = %{site_id: site_id, code: "traffic.volume", channel_name: "live"}
      %{state | pending_fetches: Map.put(state.pending_fetches, correlation_id, pending_fetch)}
    end)

    payload =
      RSMP.Utility.to_payload(%{
        "values" => %{"cars" => 1},
        "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "seq" => 1,
        "complete" => true
      })

    properties = %{"Correlation-Data": correlation_id}
    send(pid, {:publish, %{topic: "#{supervisor_id}/history/traffic.volume/live", payload: payload, properties: properties}})

    :timer.sleep(50)

    state = :sys.get_state(pid)
    assert Map.get(state.pending_fetches, correlation_id) == nil
  end

  test "receive_history ignores messages with unknown correlation data", %{supervisor_id: supervisor_id, pid: pid} do
    site_id = "supervisor_history_unknown_#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(RSMP.PubSub, "supervisor:#{supervisor_id}:#{site_id}")

    payload =
      RSMP.Utility.to_payload(%{
        "values" => %{"cars" => 1},
        "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "seq" => 1,
        "complete" => true
      })

    properties = %{"Correlation-Data": "unknown-corr-id"}
    send(pid, {:publish, %{topic: "#{supervisor_id}/history/traffic.volume/live", payload: payload, properties: properties}})

    # Should not broadcast data_point since correlation is unknown
    refute_receive %{topic: "data_point"}, 50
  end

  test "receive_history with empty response (complete: true, no values)", %{supervisor_id: supervisor_id, pid: pid} do
    site_id = "supervisor_history_empty_#{System.unique_integer([:positive])}"

    correlation_id = "test-corr-#{System.unique_integer([:positive])}"
    :sys.replace_state(pid, fn state ->
      pending_fetch = %{site_id: site_id, code: "traffic.volume", channel_name: "live"}
      %{state | pending_fetches: Map.put(state.pending_fetches, correlation_id, pending_fetch)}
    end)

    payload = RSMP.Utility.to_payload(%{"complete" => true})

    properties = %{"Correlation-Data": correlation_id}
    send(pid, {:publish, %{topic: "#{supervisor_id}/history/traffic.volume/live", payload: payload, properties: properties}})

    :timer.sleep(50)

    # Pending fetch should be cleared
    state = :sys.get_state(pid)
    assert Map.get(state.pending_fetches, correlation_id) == nil
  end

  test "history fills gaps making graph data contiguous", %{supervisor_id: supervisor_id, pid: pid} do
    site_id = "supervisor_history_graph_#{System.unique_integer([:positive])}"
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    correlation_id = "test-corr-#{System.unique_integer([:positive])}"
    :sys.replace_state(pid, fn state ->
      pending_fetch = %{site_id: site_id, code: "traffic.volume", channel_name: "live"}
      %{state | pending_fetches: Map.put(state.pending_fetches, correlation_id, pending_fetch)}
    end)

    # Send live data missing seq 3
    for seq <- [1, 2, 4, 5] do
      _ts = DateTime.add(now, -6 + seq)

      payload =
        RSMP.Utility.to_payload(%{
          "type" => "full",
          "seq" => seq,
          "data" => %{"cars" => seq}
        })

      send(pid, {:publish, %{topic: "#{site_id}/status/traffic.volume/live", payload: payload, properties: %{}}})
    end

    :timer.sleep(50)
    assert RSMP.Supervisor.has_seq_gaps?(supervisor_id, site_id, "traffic.volume/live") == true

    # Send history to fill seq 3
    payload =
      RSMP.Utility.to_payload(%{
        "values" => %{"cars" => 3},
        "ts" => DateTime.add(now, -3) |> DateTime.to_iso8601(),
        "seq" => 3,
        "complete" => true
      })

    properties = %{"Correlation-Data": correlation_id}
    send(pid, {:publish, %{topic: "#{supervisor_id}/history/traffic.volume/live", payload: payload, properties: properties}})

    :timer.sleep(50)

    assert RSMP.Supervisor.has_seq_gaps?(supervisor_id, site_id, "traffic.volume/live") == false
    points = RSMP.Supervisor.data_points(supervisor_id, site_id, "traffic.volume/live")
    assert length(points) == 5
    cars = Enum.map(points, fn %{values: v} -> v.cars end)
    assert Enum.sort(cars) == [1, 2, 3, 4, 5]
  end

  # ---------------------------------------------------------------------------
  # TrafficConverter unit tests
  # ---------------------------------------------------------------------------

  describe "TrafficConverter.from_rsmp_status" do
    test "fills zeros for all missing counters when only one is present", _ctx do
      result = RSMP.Converter.Traffic.from_rsmp_status("traffic.volume", %{"cars" => 5})
      assert result == %{cars: 5, bicycles: 0, busses: 0}
    end

    test "preserves all provided counters and fills no implicit zeros", _ctx do
      result = RSMP.Converter.Traffic.from_rsmp_status("traffic.volume", %{
        "cars" => 3, "bicycles" => 2, "busses" => 1
      })
      assert result == %{cars: 3, bicycles: 2, busses: 1}
    end

    test "fills all zeros when payload is empty", _ctx do
      result = RSMP.Converter.Traffic.from_rsmp_status("traffic.volume", %{})
      assert result == %{cars: 0, bicycles: 0, busses: 0}
    end

    test "accepts atom keys and converts them", _ctx do
      result = RSMP.Converter.Traffic.from_rsmp_status("traffic.volume", %{cars: 10})
      assert result == %{cars: 10, bicycles: 0, busses: 0}
    end
  end
end
