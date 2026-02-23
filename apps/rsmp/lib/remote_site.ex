# RSMP Site
defmodule RSMP.Remote.Node.Site do
  @moduledoc false

  # Maximum number of data points stored per channel key (e.g. 1 hour at 1/s)
  @max_data_points 3600

  defstruct(
    id: nil,
    presence: "offline",
    modules: %{},
    statuses: %{},
    channels: %{},
    alarms: %{},
    num_alarms: 0,
    # %{ "traffic.volume/live" => %{ seq_or_key => %{ts: DateTime, values: map} } }
    data_points: %{},
    # %{ channel_key => DateTime.t() } — when each channel was last stopped
    channel_stopped_at: %{}
  )

  # api
  def new(options \\ []) do
    remote = __struct__(options)
    %{remote | modules: module_mapping([RSMP.Module.TLC, RSMP.Module.Traffic])}
  end

  # Store a data point for a given channel key. Deduplicates by seq when non-nil.
  # Trims to @max_data_points oldest-first by ts.
  # Optionally stores next_ts to indicate when the next event occurs.
  def store_data_point(site, channel_key, seq, ts, values, next_ts \\ nil) do
    existing = Map.get(site.data_points, channel_key, %{})
    # Use seq as map key when available; fall back to a monotonic integer
    key = if seq != nil, do: seq, else: System.unique_integer([:monotonic])
    point = %{ts: ts, values: values, next_ts: next_ts}

    updated =
      if map_size(existing) >= @max_data_points do
        # Evict the entry with the oldest ts before inserting the new one
        oldest_key =
          Enum.min_by(existing, fn {_k, v} -> DateTime.to_unix(v.ts, :microsecond) end)
          |> elem(0)
        existing |> Map.delete(oldest_key) |> Map.put(key, point)
      else
        Map.put(existing, key, point)
      end

    %{site | data_points: Map.put(site.data_points, channel_key, updated)}
  end

  # Set next_ts on the most recent data point for a channel key.
  # Called when a channel stops or site goes offline, to mark the
  # end of the last known state.
  def stamp_next_ts_on_last(site, channel_key, next_ts) do
    points_map = Map.get(site.data_points, channel_key, %{})

    if map_size(points_map) == 0 do
      site
    else
      {latest_key, latest_point} =
        Enum.max_by(points_map, fn {_k, v} -> DateTime.to_unix(v.ts, :microsecond) end)

      # Only stamp if next_ts is not already set
      if latest_point[:next_ts] do
        site
      else
        updated_point = Map.put(latest_point, :next_ts, next_ts)
        updated = Map.put(points_map, latest_key, updated_point)
        %{site | data_points: Map.put(site.data_points, channel_key, updated)}
      end
    end
  end

  # Clear next_ts on the data point just before a given timestamp.
  # Called when replay data arrives to remove the disconnect gap marker,
  # since the replay fills the gap. Only clears the point whose ts is
  # earlier than `before_ts`, so replay-provided next_ts values are preserved.
  def clear_next_ts_before(site, channel_key, before_ts) do
    points_map = Map.get(site.data_points, channel_key, %{})
    before_us = DateTime.to_unix(before_ts, :microsecond)

    earlier =
      Enum.filter(points_map, fn {_k, v} -> DateTime.to_unix(v.ts, :microsecond) < before_us end)

    if earlier == [] do
      site
    else
      {latest_key, latest_point} =
        Enum.max_by(earlier, fn {_k, v} -> DateTime.to_unix(v.ts, :microsecond) end)

      if latest_point[:next_ts] do
        updated_point = Map.delete(latest_point, :next_ts)
        updated = Map.put(points_map, latest_key, updated_point)
        %{site | data_points: Map.put(site.data_points, channel_key, updated)}
      else
        site
      end
    end
  end

  # Return data points for a channel key as a list sorted by ts (oldest first).
  def get_data_points(site, channel_key) do
    site.data_points
    |> Map.get(channel_key, %{})
    |> Map.values()
    |> Enum.sort_by(fn %{ts: ts} -> DateTime.to_unix(ts, :microsecond) end)
  end

  # Return data points with their keys as {key, point} tuples sorted by ts.
  def get_data_points_with_keys(site, channel_key) do
    site.data_points
    |> Map.get(channel_key, %{})
    |> Enum.sort_by(fn {_k, v} -> DateTime.to_unix(v.ts, :microsecond) end)
  end

  # Detect gaps in seq numbers for a channel key.
  # Returns a list of {from_seq, to_seq} ranges representing missing seq numbers.
  def seq_gaps(site, channel_key) do
    seqs =
      site.data_points
      |> Map.get(channel_key, %{})
      |> Map.keys()
      |> Enum.filter(&is_integer/1)
      |> Enum.sort()

    find_gaps(seqs)
  end

  # Returns true if there are any gaps in seq numbers for the channel key.
  def has_seq_gaps?(site, channel_key) do
    seq_gaps(site, channel_key) != []
  end

  # Convert seq gaps to time ranges using the timestamps of the neighboring seqs.
  # Returns a list of {from_ts, to_ts} where from_ts is the ts of the seq before
  # the gap and to_ts is the ts of the seq after the gap.
  def gap_time_ranges(site, channel_key) do
    points = Map.get(site.data_points, channel_key, %{})
    gaps = seq_gaps(site, channel_key)

    Enum.flat_map(gaps, fn {gap_start, gap_end} ->
      before_ts = get_in(points, [gap_start - 1, :ts])
      after_ts = get_in(points, [gap_end + 1, :ts])

      case {before_ts, after_ts} do
        {nil, nil} -> []
        {from, nil} -> [{from, nil}]
        {nil, to} -> [{nil, to}]
        {from, to} -> [{from, to}]
      end
    end)
  end

  defp find_gaps([]), do: []
  defp find_gaps([_single]), do: []

  defp find_gaps(sorted_seqs) do
    sorted_seqs
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [a, b] ->
      if b - a > 1, do: [{a + 1, b - 1}], else: []
    end)
  end

  # Aggregate data points into 1-second bins aligned to wall-clock time.
  # Returns exactly `max_bins` bin maps (oldest first), ending at `now`.
  # Each bin sums the values of all data points falling within that second.
  # Seconds with no data are filled with zeros.
  def aggregate_into_bins(data_points, max_bins, now \\ DateTime.utc_now()) do
    zero = %{cars: 0, bicycles: 0, busses: 0}
    now_truncated = DateTime.truncate(now, :second)

    bin_map =
      data_points
      |> Enum.group_by(fn %{ts: ts} -> DateTime.truncate(ts, :second) end)
      |> Map.new(fn {second, points} ->
        values =
          Enum.reduce(points, zero, fn %{values: v}, acc ->
            %{
              cars: acc.cars + Map.get(v, :cars, 0),
              bicycles: acc.bicycles + Map.get(v, :bicycles, 0),
              busses: acc.busses + Map.get(v, :busses, 0)
            }
          end)

        {second, values}
      end)

    for i <- (max_bins - 1)..0//-1 do
      second = DateTime.add(now_truncated, -i, :second)
      Map.get(bin_map, second, zero)
    end
  end

  def module(site, name), do: site.modules |> Map.fetch!(name)
  def responder(site, name), do: module(site, name).responder
  def converter(site, name), do: module(site, name).converter

  def from_rsmp_status(site, path, data) do
    converter(site, path.module).from_rsmp_status(path.code, data)
  end

  def to_rsmp_status(site, path, data) do
    converter(site, path.module).to_rsmp_status(path.code, data)
  end

  def module_mapping(module_list) do
    for module <- module_list, into: %{}, do: {module.name(), module}
  end
end
