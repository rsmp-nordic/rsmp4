# RSMP Site
defmodule RSMP.Remote.Node.Site do
  @moduledoc false

  # Maximum number of data points stored per stream key (e.g. 1 hour at 1/s)
  @max_data_points 3600

  defstruct(
    id: nil,
    presence: "offline",
    modules: %{},
    statuses: %{},
    streams: %{},
    alarms: %{},
    num_alarms: 0,
    # %{ "traffic.volume/live" => %{ seq_or_key => %{ts: DateTime, values: map} } }
    data_points: %{}
  )

  # api
  def new(options \\ []) do
    remote = __struct__(options)
    %{remote | modules: module_mapping([RSMP.Module.TLC, RSMP.Module.Traffic])}
  end

  # Store a data point for a given stream key. Deduplicates by seq when non-nil.
  # Trims to @max_data_points oldest-first by ts.
  def store_data_point(site, stream_key, seq, ts, values) do
    existing = Map.get(site.data_points, stream_key, %{})
    # Use seq as map key when available; fall back to a monotonic integer
    key = if seq != nil, do: seq, else: System.unique_integer([:monotonic])
    point = %{ts: ts, values: values}

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

    %{site | data_points: Map.put(site.data_points, stream_key, updated)}
  end

  # Return data points for a stream key as a list sorted by ts (oldest first).
  def get_data_points(site, stream_key) do
    site.data_points
    |> Map.get(stream_key, %{})
    |> Map.values()
    |> Enum.sort_by(fn %{ts: ts} -> DateTime.to_unix(ts, :microsecond) end)
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
