defmodule RSMP.SupervisorTest do
  use ExUnit.Case

  setup do
    supervisor_id = "sup_test_#{System.unique_integer([:positive])}"
    site_id = "site_test_#{System.unique_integer([:positive])}"

    {:ok, pid} = RSMP.Remote.SiteData.start_link({supervisor_id, site_id})

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    %{supervisor_id: supervisor_id, site_id: site_id, pid: pid}
  end

  defp send_status(pid, site_id, code, channel_name, data, properties \\ %{}) do
    topic = RSMP.Topic.new(site_id, "status", code, channel_name)
    GenServer.cast(pid, {:receive, "status", topic, data, properties})
    :timer.sleep(20)
  end

  defp send_replay(pid, site_id, code, channel_name, data) do
    topic = RSMP.Topic.new(site_id, "replay", code, channel_name)
    GenServer.cast(pid, {:receive, "replay", topic, data, %{}})
    :timer.sleep(20)
  end

  defp send_history(pid, site_id, code, channel_name, data, properties) do
    topic = RSMP.Topic.new(site_id, "history", code, channel_name)
    GenServer.cast(pid, {:receive, "history", topic, data, properties})
    :timer.sleep(20)
  end

  defp get_site(supervisor_id, site_id) do
    RSMP.Remote.SiteData.get_state(supervisor_id, site_id)
  end

  test "keeps previous groups stage when delta omits stage", %{supervisor_id: supervisor_id, site_id: site_id, pid: pid} do
    send_status(pid, site_id, "tlc.groups", "live", %{
      "entries" => [%{
        "values" => %{
          "signalgroupstatus" => "GrGr",
          "stage" => 2,
          "cyclecounter" => 10
        }
      }]
    })

    send_status(pid, site_id, "tlc.groups", "live", %{
      "entries" => [%{
        "values" => %{
          "signalgroupstatus" => "YrYr",
          "cyclecounter" => 11
        }
      }]
    })

    status = get_site(supervisor_id, site_id).statuses["tlc.groups"]
    assert status.groups == %{"1" => "Y", "2" => "r", "3" => "Y", "4" => "r"}
    assert status.cycle == 11
    assert status.stage == 2
  end

  test "traffic.volume live delta: missing counters imply zero, stale values are cleared", %{supervisor_id: supervisor_id, site_id: site_id, pid: pid} do
    send_status(pid, site_id, "traffic.volume", "live", %{
      "entries" => [%{"values" => %{"cars" => 4}}]
    })

    send_status(pid, site_id, "traffic.volume", "live", %{
      "entries" => [%{"values" => %{"cars" => 6}}]
    })

    status = get_site(supervisor_id, site_id).statuses["traffic.volume"]
    assert status.cars == 6

    send_status(pid, site_id, "traffic.volume", "live", %{
      "entries" => [%{"values" => %{"bicycles" => 2}}]
    })

    status = get_site(supervisor_id, site_id).statuses["traffic.volume"]
    assert status.bicycles == 2
    assert status.cars == 0
    assert status.busses == 0
  end

  test "traffic.volume 5s channel does not overwrite live display values", %{supervisor_id: supervisor_id, site_id: site_id, pid: pid} do
    send_status(pid, site_id, "traffic.volume", "live", %{
      "entries" => [%{"values" => %{"cars" => 3}}]
    })

    status = get_site(supervisor_id, site_id).statuses["traffic.volume"]
    assert status.cars == 3

    send_status(pid, site_id, "traffic.volume", "5s", %{
      "entries" => [%{"values" => %{"cars" => 99, "bicycles" => 99, "busses" => 99}, "seq" => 1}]
    })

    status = get_site(supervisor_id, site_id).statuses["traffic.volume"]
    assert status.cars == 3
    assert status.bicycles == 0
    assert status.busses == 0

    seq = get_in(status, [:seq]) || get_in(status, ["seq"])
    assert is_map(seq)
    assert Map.get(seq, "5s") == 1
  end

  # ---------------------------------------------------------------------------
  # Replay
  # ---------------------------------------------------------------------------

  test "receive_replay broadcasts data_point with source :replay", %{supervisor_id: supervisor_id, site_id: site_id, pid: pid} do
    Phoenix.PubSub.subscribe(RSMP.PubSub, "supervisor:#{supervisor_id}:#{site_id}")

    send_replay(pid, site_id, "traffic.volume", "live", %{
      "entries" => [%{
        "values" => %{"cars" => 3, "bicycles" => 1},
        "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "seq" => 1
      }]
    })

    assert_receive %{topic: "data_point", source: :replay, path: "traffic.volume", channel: "live"}
  end

  test "receive_replay includes values converted via traffic converter", %{supervisor_id: supervisor_id, site_id: site_id, pid: pid} do
    Phoenix.PubSub.subscribe(RSMP.PubSub, "supervisor:#{supervisor_id}:#{site_id}")

    send_replay(pid, site_id, "traffic.volume", "live", %{
      "entries" => [%{
        "values" => %{"cars" => 7, "bicycles" => 2, "busses" => 0},
        "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "seq" => 5
      }]
    })

    assert_receive %{topic: "data_point", source: :replay, values: values}
    assert values.cars == 7
    assert values.bicycles == 2
  end

  test "receive_replay includes seq and ts from payload", %{supervisor_id: supervisor_id, site_id: site_id, pid: pid} do
    Phoenix.PubSub.subscribe(RSMP.PubSub, "supervisor:#{supervisor_id}:#{site_id}")
    ts = DateTime.utc_now() |> DateTime.truncate(:second)

    send_replay(pid, site_id, "traffic.volume", "live", %{
      "entries" => [%{
        "values" => %{"cars" => 1},
        "ts" => ts |> DateTime.to_iso8601(),
        "seq" => 42
      }]
    })

    assert_receive %{topic: "data_point", source: :replay, seq: 42, ts: ^ts}
  end

  test "receive_replay broadcasts multiple points preserving order", %{supervisor_id: supervisor_id, site_id: site_id, pid: pid} do
    Phoenix.PubSub.subscribe(RSMP.PubSub, "supervisor:#{supervisor_id}:#{site_id}")

    for seq <- 1..5 do
      send_replay(pid, site_id, "traffic.volume", "live", %{
        "entries" => [%{
          "values" => %{"cars" => seq},
          "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "seq" => seq
        }]
      })
    end

    received =
      for _i <- 1..5 do
        assert_receive %{topic: "data_point", source: :replay, seq: seq}
        seq
      end

    assert received == [1, 2, 3, 4, 5]
  end

  test "receive_replay ignores payload without 'values' key", %{supervisor_id: supervisor_id, site_id: site_id, pid: pid} do
    Phoenix.PubSub.subscribe(RSMP.PubSub, "supervisor:#{supervisor_id}:#{site_id}")

    send_replay(pid, site_id, "traffic.volume", "live", %{
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601()
    })

    refute_receive %{topic: "data_point"}, 50
  end

  test "live status data_point has source :live (not :replay)", %{supervisor_id: supervisor_id, site_id: site_id, pid: pid} do
    Phoenix.PubSub.subscribe(RSMP.PubSub, "supervisor:#{supervisor_id}:#{site_id}")

    send_status(pid, site_id, "traffic.volume", "live", %{
      "entries" => [%{"values" => %{"cars" => 2}}]
    })

    assert_receive %{topic: "data_point"} = msg
    assert msg.source == :live
  end

  test "traffic.volume seq is latest channel seq", %{supervisor_id: supervisor_id, site_id: site_id, pid: pid} do
    send_status(pid, site_id, "traffic.volume", "live", %{
      "entries" => [%{"values" => %{"cars" => 4}, "seq" => 64}]
    })

    status = get_site(supervisor_id, site_id).statuses["traffic.volume"]
    assert status["seq"] == %{"live" => 64}

    send_status(pid, site_id, "traffic.volume", "5s", %{
      "entries" => [%{"values" => %{"cars" => 4, "bicycles" => 1}, "seq" => 12}]
    })

    status = get_site(supervisor_id, site_id).statuses["traffic.volume"]
    assert status["seq"] == %{"live" => 64, "5s" => 12}
  end

  # ---------------------------------------------------------------------------
  # Data points storage
  # ---------------------------------------------------------------------------

  test "live status stores data points keyed by seq", %{supervisor_id: supervisor_id, site_id: site_id, pid: pid} do
    for seq <- 1..5 do
      send_status(pid, site_id, "traffic.volume", "live", %{
        "entries" => [%{"values" => %{"cars" => seq}, "seq" => seq}]
      })
    end

    points = RSMP.Remote.SiteData.data_points(supervisor_id, site_id, "traffic.volume/live")
    assert length(points) == 5
    cars = Enum.map(points, fn %{values: v} -> v.cars end)
    assert cars == [1, 2, 3, 4, 5]
  end

  test "replay stores data points keyed by seq without duplicates", %{supervisor_id: supervisor_id, site_id: site_id, pid: pid} do
    for seq <- 1..3 do
      send_replay(pid, site_id, "traffic.volume", "live", %{
        "entries" => [%{
          "values" => %{"cars" => seq},
          "ts" => DateTime.utc_now() |> DateTime.add(-10 + seq) |> DateTime.to_iso8601(),
          "seq" => seq
        }]
      })
    end

    points = RSMP.Remote.SiteData.data_points(supervisor_id, site_id, "traffic.volume/live")
    assert length(points) == 3

    send_replay(pid, site_id, "traffic.volume", "live", %{
      "entries" => [%{
        "values" => %{"cars" => 99},
        "ts" => DateTime.utc_now() |> DateTime.add(-8) |> DateTime.to_iso8601(),
        "seq" => 2
      }]
    })

    points = RSMP.Remote.SiteData.data_points(supervisor_id, site_id, "traffic.volume/live")
    assert length(points) == 3
    cars = Enum.map(points, fn %{values: v} -> v.cars end)
    assert 99 in cars
  end

  test "concurrent live and replay data stored correctly", %{supervisor_id: supervisor_id, site_id: site_id, pid: pid} do
    now = DateTime.utc_now()

    for seq <- 11..13 do
      send_status(pid, site_id, "traffic.volume", "live", %{
        "entries" => [%{"values" => %{"cars" => seq}, "seq" => seq}]
      })
    end

    for seq <- 1..5 do
      ts = DateTime.add(now, -20 + seq) |> DateTime.to_iso8601()

      send_replay(pid, site_id, "traffic.volume", "live", %{
        "entries" => [%{
          "values" => %{"cars" => seq},
          "ts" => ts,
          "seq" => seq
        }]
      })
    end

    points = RSMP.Remote.SiteData.data_points(supervisor_id, site_id, "traffic.volume/live")
    assert length(points) == 8

    timestamps = Enum.map(points, fn %{ts: t} -> DateTime.to_unix(t, :microsecond) end)
    assert timestamps == Enum.sort(timestamps)
  end

  test "data points aggregate into bins with correct backfill", %{supervisor_id: supervisor_id, site_id: site_id, pid: pid} do
    for i <- 5..1//-1 do
      send_status(pid, site_id, "traffic.volume", "live", %{
        "entries" => [%{"values" => %{"cars" => 1}, "seq" => 100 - i}]
      })
    end

    points = RSMP.Remote.SiteData.data_points(supervisor_id, site_id, "traffic.volume/live")
    assert length(points) == 5

    now = DateTime.utc_now()
    bins = RSMP.Remote.Node.Site.aggregate_into_bins(points, 10, now)
    assert length(bins) == 10

    total_cars = Enum.reduce(bins, 0, fn b, acc -> acc + b.cars end)
    assert total_cars == 5
  end

  # ---------------------------------------------------------------------------
  # History (fetch response)
  # ---------------------------------------------------------------------------

  test "receive_history broadcasts data_point with source :history", %{supervisor_id: supervisor_id, site_id: site_id, pid: pid} do
    Phoenix.PubSub.subscribe(RSMP.PubSub, "supervisor:#{supervisor_id}:#{site_id}")

    correlation_id = "test-corr-#{System.unique_integer([:positive])}"
    :sys.replace_state(pid, fn state ->
      pending_fetch = %{site_id: site_id, code: "traffic.volume", channel_name: "live"}
      %{state | pending_fetches: Map.put(state.pending_fetches, correlation_id, pending_fetch)}
    end)

    send_history(pid, site_id, "traffic.volume", "live", %{
      "entries" => [%{
        "values" => %{"cars" => 3, "bicycles" => 1},
        "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "seq" => 42
      }],
      "complete" => false
    }, %{"Correlation-Data": correlation_id})

    assert_receive %{topic: "data_point", source: :history, path: "traffic.volume", channel: "live", seq: 42}
  end

  test "receive_history stores data points by seq", %{supervisor_id: supervisor_id, site_id: site_id, pid: pid} do
    correlation_id = "test-corr-#{System.unique_integer([:positive])}"
    :sys.replace_state(pid, fn state ->
      pending_fetch = %{site_id: site_id, code: "traffic.volume", channel_name: "live"}
      %{state | pending_fetches: Map.put(state.pending_fetches, correlation_id, pending_fetch)}
    end)

    for seq <- [1, 2, 5, 6] do
      send_status(pid, site_id, "traffic.volume", "live", %{
        "entries" => [%{"values" => %{"cars" => seq}, "seq" => seq}]
      })
    end

    for seq <- [3, 4] do
      send_history(pid, site_id, "traffic.volume", "live", %{
        "entries" => [%{
          "values" => %{"cars" => seq},
          "ts" => DateTime.utc_now() |> DateTime.add(-10 + seq) |> DateTime.to_iso8601(),
          "seq" => seq
        }],
        "complete" => (seq == 4)
      }, %{"Correlation-Data": correlation_id})
    end

    points = RSMP.Remote.SiteData.data_points(supervisor_id, site_id, "traffic.volume/live")
    assert length(points) == 6
  end

  test "receive_history clears pending fetch on complete", %{site_id: site_id, pid: pid} do
    correlation_id = "test-corr-#{System.unique_integer([:positive])}"
    :sys.replace_state(pid, fn state ->
      pending_fetch = %{site_id: site_id, code: "traffic.volume", channel_name: "live"}
      %{state | pending_fetches: Map.put(state.pending_fetches, correlation_id, pending_fetch)}
    end)

    send_history(pid, site_id, "traffic.volume", "live", %{
      "entries" => [%{
        "values" => %{"cars" => 1},
        "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "seq" => 1
      }],
      "complete" => true
    }, %{"Correlation-Data": correlation_id})

    state = :sys.get_state(pid)
    assert Map.get(state.pending_fetches, correlation_id) == nil
  end

  test "receive_history ignores messages with unknown correlation data", %{supervisor_id: supervisor_id, site_id: site_id, pid: pid} do
    Phoenix.PubSub.subscribe(RSMP.PubSub, "supervisor:#{supervisor_id}:#{site_id}")

    send_history(pid, site_id, "traffic.volume", "live", %{
      "entries" => [%{
        "values" => %{"cars" => 1},
        "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "seq" => 1
      }],
      "complete" => true
    }, %{"Correlation-Data": "unknown-corr-id"})

    refute_receive %{topic: "data_point"}, 50
  end

  test "receive_history with empty response (complete: true, no entries)", %{site_id: site_id, pid: pid} do
    correlation_id = "test-corr-#{System.unique_integer([:positive])}"
    :sys.replace_state(pid, fn state ->
      pending_fetch = %{site_id: site_id, code: "traffic.volume", channel_name: "live"}
      %{state | pending_fetches: Map.put(state.pending_fetches, correlation_id, pending_fetch)}
    end)

    send_history(pid, site_id, "traffic.volume", "live", %{
      "complete" => true
    }, %{"Correlation-Data": correlation_id})

    state = :sys.get_state(pid)
    assert Map.get(state.pending_fetches, correlation_id) == nil
  end

  test "history fills gaps making graph data contiguous", %{supervisor_id: supervisor_id, site_id: site_id, pid: pid} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    correlation_id = "test-corr-#{System.unique_integer([:positive])}"
    :sys.replace_state(pid, fn state ->
      pending_fetch = %{site_id: site_id, code: "traffic.volume", channel_name: "live"}
      %{state | pending_fetches: Map.put(state.pending_fetches, correlation_id, pending_fetch)}
    end)

    for seq <- [1, 2, 4, 5] do
      send_status(pid, site_id, "traffic.volume", "live", %{
        "entries" => [%{"values" => %{"cars" => seq}, "seq" => seq}]
      })
    end

    gaps = RSMP.Remote.SiteData.gap_time_ranges(supervisor_id, site_id, "traffic.volume/live")
    assert length(gaps) > 0

    send_history(pid, site_id, "traffic.volume", "live", %{
      "entries" => [%{
        "values" => %{"cars" => 3},
        "ts" => DateTime.add(now, -3) |> DateTime.to_iso8601(),
        "seq" => 3
      }],
      "complete" => true
    }, %{"Correlation-Data": correlation_id})

    points = RSMP.Remote.SiteData.data_points(supervisor_id, site_id, "traffic.volume/live")
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
