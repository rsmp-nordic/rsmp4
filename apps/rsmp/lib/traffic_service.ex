defmodule RSMP.Service.Traffic do
	use RSMP.Service, name: "traffic"

	@vehicle_types ["cars", "bicycles", "busses"]
	@zero_volume %{"cars" => 0, "bicycles" => 0, "busses" => 0}
	@traffic_levels [:none, :sparse, :low, :high]
	@max_data_points 3600

	@impl true
	def status_codes(), do: ["volume"]

	@impl true
	def alarm_codes(), do: []

	defstruct(
		id: nil,
		last_detection: @zero_volume,
		traffic_level: :low,
		detection_timers: %{},
		data_points: []
	)

	@impl RSMP.Service.Behaviour
	def new(id, _data \\ %{}) do
		detection_timers = schedule_all_detections(:low)
		%__MODULE__{id: id, detection_timers: detection_timers}
	end

	@impl GenServer
	def handle_info({:tick_detection, mode}, service) do
		service = put_in(service.detection_timers[mode], nil)

		case service.traffic_level do
			:none ->
				{:noreply, service}

			level ->
				count = Enum.random(1..8)
				ts = DateTime.utc_now()

				detection_event = %{mode => count}
				last_detection = Map.put(@zero_volume, mode, count)

				RSMP.Service.report_to_channels(service.id, "traffic", "volume", detection_event, ts)
				Phoenix.PubSub.broadcast(RSMP.PubSub, "site:#{service.id}", %{topic: "local_status", changes: ["traffic.volume"]})

				point = %{ts: ts, values: to_atom_keys(detection_event)}
				data_points = RSMP.DataHistory.push(service.data_points, point, @max_data_points)

				timer = schedule_next_detection(mode, level)
				detection_timers = Map.put(service.detection_timers, mode, timer)
				{:noreply, %{service | last_detection: last_detection, detection_timers: detection_timers, data_points: data_points}}
		end
	end

	@impl GenServer
	def handle_call(:get_traffic_level, _from, service) do
		{:reply, service.traffic_level, service}
	end

	@impl GenServer
	def handle_call(:get_data_points, _from, service) do
		{:reply, service.data_points, service}
	end

	@impl GenServer
	def handle_cast({:set_traffic_level, level}, service) when level in @traffic_levels do
		service = cancel_all_detection_timers(service)
		service = %{service | traffic_level: level}

		service =
			case level do
				:none -> service
				_ -> %{service | detection_timers: schedule_all_detections(level)}
			end

		{:noreply, service}
	end

	@impl GenServer
	def handle_cast({:set_traffic_level, _invalid_level}, service) do
		{:noreply, service}
	end

	defp schedule_all_detections(level) do
		Enum.into(@vehicle_types, %{}, fn mode ->
			{mode, schedule_next_detection(mode, level)}
		end)
	end

	defp schedule_next_detection(mode, :high), do: Process.send_after(self(), {:tick_detection, mode}, random_detection_interval_ms(:high))
	defp schedule_next_detection(mode, :low), do: Process.send_after(self(), {:tick_detection, mode}, random_detection_interval_ms(:low))
	defp schedule_next_detection(mode, :sparse), do: Process.send_after(self(), {:tick_detection, mode}, random_detection_interval_ms(:sparse))

	defp cancel_all_detection_timers(service) do
		Enum.each(service.detection_timers, fn
			{_mode, nil} -> :ok
			{_mode, ref} -> Process.cancel_timer(ref)
		end)
		%{service | detection_timers: %{}}
	end

	defp random_detection_interval_ms(:sparse) do
		Enum.random(2500..25000)
	end

	defp random_detection_interval_ms(:low) do
		Enum.random(500..5000)
	end

	defp random_detection_interval_ms(:high) do
		Enum.random(100..1000)
	end

	defp to_atom_keys(map) when is_map(map) do
		Enum.into(map, %{}, fn {k, v} -> {String.to_atom(k), v} end)
	end

end

defimpl RSMP.Service.Protocol, for: RSMP.Service.Traffic do
	def name(_service), do: "traffic"
	def id(service), do: service.id

	def receive_command(service, _topic, _data, _properties), do: {service, nil}

	def format_status(service, "volume") do
		service.last_detection
	end
end
