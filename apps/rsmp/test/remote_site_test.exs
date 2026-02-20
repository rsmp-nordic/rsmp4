defmodule RSMP.Remote.Node.SiteTest do
  use ExUnit.Case, async: true

  alias RSMP.Remote.Node.Site

  # Helper to build a DateTime at a specific second offset from a base time
  defp ts(base, offset_seconds) do
    DateTime.add(base, offset_seconds, :second)
  end

  # ---------------------------------------------------------------------------
  # store_data_point
  # ---------------------------------------------------------------------------

  describe "store_data_point" do
    test "stores a data point keyed by seq" do
      site = Site.new()
      site = Site.store_data_point(site, "traffic.volume/live", 1, ~U[2025-01-01 00:00:01Z], %{cars: 3})
      site = Site.store_data_point(site, "traffic.volume/live", 2, ~U[2025-01-01 00:00:02Z], %{cars: 5})

      points = Site.get_data_points(site, "traffic.volume/live")
      assert length(points) == 2
      assert Enum.at(points, 0).values == %{cars: 3}
      assert Enum.at(points, 1).values == %{cars: 5}
    end

    test "deduplicates by seq — later store overwrites earlier" do
      site = Site.new()
      site = Site.store_data_point(site, "traffic.volume/live", 5, ~U[2025-01-01 00:00:05Z], %{cars: 1})
      site = Site.store_data_point(site, "traffic.volume/live", 5, ~U[2025-01-01 00:00:05Z], %{cars: 99})

      points = Site.get_data_points(site, "traffic.volume/live")
      assert length(points) == 1
      assert hd(points).values == %{cars: 99}
    end

    test "separate stream keys are independent" do
      site = Site.new()
      site = Site.store_data_point(site, "traffic.volume/live", 1, ~U[2025-01-01 00:00:01Z], %{cars: 1})
      site = Site.store_data_point(site, "traffic.volume/5s", 1, ~U[2025-01-01 00:00:01Z], %{cars: 2})

      assert length(Site.get_data_points(site, "traffic.volume/live")) == 1
      assert length(Site.get_data_points(site, "traffic.volume/5s")) == 1
    end

    test "uses monotonic key when seq is nil" do
      site = Site.new()
      site = Site.store_data_point(site, "traffic.volume/live", nil, ~U[2025-01-01 00:00:01Z], %{cars: 1})
      site = Site.store_data_point(site, "traffic.volume/live", nil, ~U[2025-01-01 00:00:02Z], %{cars: 2})

      points = Site.get_data_points(site, "traffic.volume/live")
      assert length(points) == 2
    end

    test "get_data_points returns sorted by ts oldest first" do
      site = Site.new()
      site = Site.store_data_point(site, "s", 3, ~U[2025-01-01 00:00:03Z], %{cars: 3})
      site = Site.store_data_point(site, "s", 1, ~U[2025-01-01 00:00:01Z], %{cars: 1})
      site = Site.store_data_point(site, "s", 2, ~U[2025-01-01 00:00:02Z], %{cars: 2})

      points = Site.get_data_points(site, "s")
      assert Enum.map(points, & &1.values.cars) == [1, 2, 3]
    end

    test "concurrent replay and live data stored correctly" do
      site = Site.new()
      # Simulate: live data at t+0..t+9, then offline, then replay at t+10..t+15 and new live at t+20..t+22
      base = ~U[2025-01-01 00:00:00Z]

      # Original live data
      site = Enum.reduce(0..9, site, fn i, s ->
        Site.store_data_point(s, "s", i, ts(base, i), %{cars: i})
      end)

      # Replay data (from offline period)
      site = Enum.reduce(10..15, site, fn i, s ->
        Site.store_data_point(s, "s", i, ts(base, i), %{cars: i})
      end)

      # New live data (after reconnect)
      site = Enum.reduce(20..22, site, fn i, s ->
        Site.store_data_point(s, "s", i, ts(base, i), %{cars: i})
      end)

      points = Site.get_data_points(site, "s")
      assert length(points) == 19
      # Should be sorted by ts
      timestamps = Enum.map(points, fn %{ts: t} -> DateTime.to_unix(t) end)
      assert timestamps == Enum.sort(timestamps)
    end
  end

  # ---------------------------------------------------------------------------
  # aggregate_into_bins
  # ---------------------------------------------------------------------------

  describe "aggregate_into_bins" do
    test "returns exactly max_bins bins" do
      bins = Site.aggregate_into_bins([], 60, ~U[2025-01-01 00:01:00Z])
      assert length(bins) == 60
    end

    test "all bins are zero when no data" do
      bins = Site.aggregate_into_bins([], 10, ~U[2025-01-01 00:00:10Z])
      assert Enum.all?(bins, fn b -> b == %{cars: 0, bicycles: 0, busses: 0} end)
    end

    test "single data point lands in correct bin" do
      now = ~U[2025-01-01 00:00:10Z]
      # Data point at now - 3 seconds, should be in bin index 6 (0-indexed from oldest)
      points = [%{ts: ~U[2025-01-01 00:00:07.500000Z], values: %{cars: 5, bicycles: 0, busses: 0}}]
      bins = Site.aggregate_into_bins(points, 10, now)

      # Bins cover seconds 1..10 (i.e. :01, :02, ..., :10)
      # Data at :07.5 truncates to :07, which is bin index 6 (0-based)
      assert Enum.at(bins, 6) == %{cars: 5, bicycles: 0, busses: 0}
      # Other bins should be zero
      assert Enum.at(bins, 5) == %{cars: 0, bicycles: 0, busses: 0}
      assert Enum.at(bins, 7) == %{cars: 0, bicycles: 0, busses: 0}
    end

    test "data in the rightmost bin (current second)" do
      now = ~U[2025-01-01 00:00:10.200000Z]
      points = [%{ts: ~U[2025-01-01 00:00:10.100000Z], values: %{cars: 3, bicycles: 0, busses: 0}}]
      bins = Site.aggregate_into_bins(points, 10, now)

      # Last bin (index 9) should have the data
      assert List.last(bins) == %{cars: 3, bicycles: 0, busses: 0}
    end

    test "data older than the window is excluded" do
      now = ~U[2025-01-01 00:00:10Z]
      # Data at second 0, window starts at second 1 (now=10, max_bins=10, so seconds 1..10)
      points = [%{ts: ~U[2025-01-01 00:00:00.500000Z], values: %{cars: 99, bicycles: 0, busses: 0}}]
      bins = Site.aggregate_into_bins(points, 10, now)

      # All bins should be zero since the data is outside the window
      assert Enum.all?(bins, fn b -> b == %{cars: 0, bicycles: 0, busses: 0} end)
    end

    test "multiple data points in the same second are summed" do
      now = ~U[2025-01-01 00:00:05Z]
      points = [
        %{ts: ~U[2025-01-01 00:00:05.100000Z], values: %{cars: 2, bicycles: 1, busses: 0}},
        %{ts: ~U[2025-01-01 00:00:05.600000Z], values: %{cars: 3, bicycles: 0, busses: 1}}
      ]
      bins = Site.aggregate_into_bins(points, 5, now)

      assert List.last(bins) == %{cars: 5, bicycles: 1, busses: 1}
    end

    test "internal gaps are zero-filled" do
      now = ~U[2025-01-01 00:00:10Z]
      # Data at seconds 2 and 8, gap in between should be zeros
      points = [
        %{ts: ~U[2025-01-01 00:00:02.000000Z], values: %{cars: 1, bicycles: 0, busses: 0}},
        %{ts: ~U[2025-01-01 00:00:08.000000Z], values: %{cars: 2, bicycles: 0, busses: 0}}
      ]
      bins = Site.aggregate_into_bins(points, 10, now)

      # Bin at second 2 = index 1 (seconds 1..10, index 0..9)
      assert Enum.at(bins, 1) == %{cars: 1, bicycles: 0, busses: 0}
      # Bin at second 8 = index 7
      assert Enum.at(bins, 7) == %{cars: 2, bicycles: 0, busses: 0}
      # Bins 2-6 (seconds 3-7) should be zero
      for i <- 2..6 do
        assert Enum.at(bins, i) == %{cars: 0, bicycles: 0, busses: 0},
               "Expected zero at bin index #{i}"
      end
    end

    test "offline gap scenario: data before gap, gap, then live data at end" do
      # Simulates: live data for seconds 1-5, offline for seconds 6-8, then live at second 9-10
      now = ~U[2025-01-01 00:00:10Z]
      base = ~U[2025-01-01 00:00:00Z]

      points =
        # Original live data seconds 1-5
        (for i <- 1..5 do
          %{ts: ts(base, i), values: %{cars: i, bicycles: 0, busses: 0}}
        end) ++
        # New live data seconds 9-10
        [
          %{ts: ts(base, 9), values: %{cars: 9, bicycles: 0, busses: 0}},
          %{ts: ts(base, 10), values: %{cars: 10, bicycles: 0, busses: 0}}
        ]

      bins = Site.aggregate_into_bins(points, 10, now)

      # Bins cover seconds 1..10
      # Seconds 1-5: data present
      for i <- 0..4 do
        assert Enum.at(bins, i).cars == i + 1, "Expected cars=#{i + 1} at bin #{i}"
      end
      # Seconds 6-8: offline gap, should be zero
      for i <- 5..7 do
        assert Enum.at(bins, i).cars == 0, "Expected zero at bin #{i} (offline gap)"
      end
      # Seconds 9-10: live data
      assert Enum.at(bins, 8).cars == 9
      assert Enum.at(bins, 9).cars == 10
    end

    test "replay backfill scenario: fills gap from the left while live fills from the right" do
      # Scenario: had data for seconds 1-10, went offline seconds 11-20,
      # came back, replay filling in 11-15 so far, live at 21-22
      now = ~U[2025-01-01 00:00:30Z]
      base = ~U[2025-01-01 00:00:00Z]

      points =
        # Old live data (seconds 1-10)
        (for i <- 1..10 do
          %{ts: ts(base, i), values: %{cars: 1, bicycles: 0, busses: 0}}
        end) ++
        # Replay data (seconds 11-15)
        (for i <- 11..15 do
          %{ts: ts(base, i), values: %{cars: 2, bicycles: 0, busses: 0}}
        end) ++
        # New live data (seconds 21-22)
        (for i <- 21..22 do
          %{ts: ts(base, i), values: %{cars: 3, bicycles: 0, busses: 0}}
        end)

      # Window: 30 bins ending at second 30, so seconds 1..30
      bins = Site.aggregate_into_bins(points, 30, now)

      # Seconds 1-10: old live data (cars=1)
      for i <- 0..9 do
        assert Enum.at(bins, i).cars == 1, "Expected cars=1 at bin #{i} (old live)"
      end
      # Seconds 11-15: replay data (cars=2)
      for i <- 10..14 do
        assert Enum.at(bins, i).cars == 2, "Expected cars=2 at bin #{i} (replay)"
      end
      # Seconds 16-20: gap not yet filled by replay (cars=0)
      for i <- 15..19 do
        assert Enum.at(bins, i).cars == 0, "Expected cars=0 at bin #{i} (unfilled gap)"
      end
      # Seconds 21-22: new live data (cars=3)
      assert Enum.at(bins, 20).cars == 3
      assert Enum.at(bins, 21).cars == 3
      # Seconds 23-30: future of live, zero
      for i <- 22..29 do
        assert Enum.at(bins, i).cars == 0, "Expected cars=0 at bin #{i} (future)"
      end
    end

    test "replay data arrives interleaved — each aggregate call produces correct snapshot" do
      now = ~U[2025-01-01 00:00:20Z]
      base = ~U[2025-01-01 00:00:00Z]

      # Start with old data seconds 1-5 and live at second 20
      site = Site.new()
      site = Enum.reduce(1..5, site, fn i, s ->
        Site.store_data_point(s, "s", i, ts(base, i), %{cars: 1, bicycles: 0, busses: 0})
      end)
      site = Site.store_data_point(site, "s", 20, ts(base, 20), %{cars: 5, bicycles: 0, busses: 0})

      points = Site.get_data_points(site, "s")
      bins = Site.aggregate_into_bins(points, 20, now)

      # Before any replay: seconds 1-5 have data, 6-19 zero, 20 has live
      assert Enum.at(bins, 0).cars == 1  # second 1
      assert Enum.at(bins, 4).cars == 1  # second 5
      assert Enum.at(bins, 5).cars == 0  # second 6 (gap)
      assert Enum.at(bins, 19).cars == 5 # second 20 (live)

      # Replay arrives: seq 6
      site = Site.store_data_point(site, "s", 6, ts(base, 6), %{cars: 2, bicycles: 0, busses: 0})
      points = Site.get_data_points(site, "s")
      bins = Site.aggregate_into_bins(points, 20, now)

      assert Enum.at(bins, 5).cars == 2  # second 6 (replay filled in)
      assert Enum.at(bins, 6).cars == 0  # second 7 (still gap)
      assert Enum.at(bins, 19).cars == 5 # second 20 (live still there)

      # More replay: seq 7, 8
      site = Site.store_data_point(site, "s", 7, ts(base, 7), %{cars: 2, bicycles: 0, busses: 0})
      site = Site.store_data_point(site, "s", 8, ts(base, 8), %{cars: 2, bicycles: 0, busses: 0})
      points = Site.get_data_points(site, "s")
      bins = Site.aggregate_into_bins(points, 20, now)

      assert Enum.at(bins, 5).cars == 2  # second 6
      assert Enum.at(bins, 6).cars == 2  # second 7
      assert Enum.at(bins, 7).cars == 2  # second 8
      assert Enum.at(bins, 8).cars == 0  # second 9 (still gap)
      assert Enum.at(bins, 19).cars == 5 # second 20 (live)
    end
  end

  # ---------------------------------------------------------------------------
  # Integration: store + aggregate combined
  # ---------------------------------------------------------------------------

  describe "store and aggregate integration" do
    test "full online/offline/replay cycle" do
      base = ~U[2025-01-01 00:00:00Z]
      site = Site.new()
      stream = "traffic.volume/live"

      # Phase 1: Site online, sends live data seq 1-10 (one per second)
      site = Enum.reduce(1..10, site, fn i, s ->
        Site.store_data_point(s, stream, i, ts(base, i), %{cars: 1, bicycles: 0, busses: 0})
      end)

      assert length(Site.get_data_points(site, stream)) == 10

      # Phase 2: Site offline for 10 seconds (seq 11-20 buffered on site side)
      # Supervisor has no new data — aggregate shows gap

      # "now" is second 25 (10 seconds of data + 10s offline + 5s for replay to start)
      now_phase2 = ts(base, 25)
      bins = Site.aggregate_into_bins(Site.get_data_points(site, stream), 30, now_phase2)

      # Bins cover seconds -4..25 (30 bins). Our data is at seconds 1-10.
      # Second 1 is at bin index 5 (bin 0 = second -4)
      # Actually: bins cover second (25-29)=second -4 through second 25
      # Let me be more precise: first bin = now - 29 = second -4, last bin = second 25
      # Data at seconds 1-10 is at bin indices 5-14
      for i <- 5..14 do
        assert Enum.at(bins, i).cars == 1, "Expected data at bin #{i}"
      end
      # Seconds 11-25: gap (zero)
      for i <- 15..29 do
        assert Enum.at(bins, i).cars == 0, "Expected gap at bin #{i}"
      end

      # Phase 3: Site comes back. Replay starts sending seq 11, 12, 13... and
      # live sends seq 21, 22... concurrently

      # Replay: seq 11-15 arrive (original timestamps)
      site = Enum.reduce(11..15, site, fn i, s ->
        Site.store_data_point(s, stream, i, ts(base, i), %{cars: 2, bicycles: 0, busses: 0})
      end)
      # Live: seq 21-22 arrive (current timestamps)
      site = Site.store_data_point(site, stream, 21, ts(base, 25), %{cars: 3, bicycles: 0, busses: 0})
      site = Site.store_data_point(site, stream, 22, ts(base, 26), %{cars: 3, bicycles: 0, busses: 0})

      now_phase3 = ts(base, 26)
      bins = Site.aggregate_into_bins(Site.get_data_points(site, stream), 30, now_phase3)
      # Window: seconds -3..26 (30 bins)
      # Bin 0 = second -3, bin 3 = second 0, bin 4 = second 1, ...
      # Second 1 => bin index 4
      # Second 10 => bin index 13
      # Second 11 => bin index 14 (replay)
      # Second 15 => bin index 18 (replay)
      # Second 16-24 => bin index 19-27 (gap)
      # Second 25 => bin index 28 (live)
      # Second 26 => bin index 29 (live)

      for i <- 4..13 do
        assert Enum.at(bins, i).cars == 1, "Expected old data at bin #{i}"
      end
      for i <- 14..18 do
        assert Enum.at(bins, i).cars == 2, "Expected replay data at bin #{i}"
      end
      for i <- 19..27 do
        assert Enum.at(bins, i).cars == 0, "Expected gap at bin #{i}"
      end
      assert Enum.at(bins, 28).cars == 3  # live
      assert Enum.at(bins, 29).cars == 3  # live

      # Phase 4: More replay arrives, filling gap further
      site = Enum.reduce(16..20, site, fn i, s ->
        Site.store_data_point(s, stream, i, ts(base, i), %{cars: 2, bicycles: 0, busses: 0})
      end)
      # More live data
      site = Site.store_data_point(site, stream, 23, ts(base, 27), %{cars: 3, bicycles: 0, busses: 0})

      now_phase4 = ts(base, 27)
      bins = Site.aggregate_into_bins(Site.get_data_points(site, stream), 30, now_phase4)
      # Window: seconds -2..27
      # Second 1 => bin 3, Second 10 => bin 12
      # Second 11-20 => bins 13-22 (all replay now)
      # Second 21-24 => bins 23-26 (gap — no data for seconds 21-24 as data points)
      # Wait: sec 25 has live data (seq 21), sec 26 has live (seq 22), sec 27 has live (seq 23)

      for i <- 3..12 do
        assert Enum.at(bins, i).cars == 1, "Expected old data at bin #{i}"
      end
      for i <- 13..22 do
        assert Enum.at(bins, i).cars == 2, "Expected replay at bin #{i}"
      end
      # Seconds 21-24 no data => bins 23-26
      for i <- 23..24 do
        assert Enum.at(bins, i).cars == 0, "Expected gap at bin #{i}"
      end
      assert Enum.at(bins, 27).cars == 3  # second 25 live
      assert Enum.at(bins, 28).cars == 3  # second 26 live
      assert Enum.at(bins, 29).cars == 3  # second 27 live
    end
  end
end
