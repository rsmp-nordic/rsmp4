defmodule RSMP.Service.Traffic do
	use RSMP.Service, name: "traffic"

	@vehicle_types ["cars", "bicycles", "busses"]
	@zero_volume %{"cars" => 0, "bicycles" => 0, "busses" => 0}
	@traffic_levels [:none, :low, :high]

	@impl true
	def status_codes(), do: ["volume"]

	@impl true
	def alarm_codes(), do: []

	defstruct(
		id: nil,
		last_detection: @zero_volume,
		traffic_level: :low,
		detection_timer: nil
	)

	@impl RSMP.Service.Behaviour
	def new(id, _data \\ %{}) do
		detection_timer = schedule_next_detection(:low)
		service = %__MODULE__{id: id, detection_timer: detection_timer}
		service
	end

	@impl GenServer
	def handle_info(:tick_detection, service) do
		service = %{service | detection_timer: nil}

		case service.traffic_level do
			:none ->
				{:noreply, service}

			level ->
				detection_volume = random_detection_volume()

				RSMP.Service.report_to_streams(service.id, "traffic", "volume", detection_volume)
				Phoenix.PubSub.broadcast(RSMP.PubSub, "site:#{service.id}", %{topic: "local_status", changes: ["traffic.volume"]})

				detection_timer = schedule_next_detection(level)
				{:noreply, %{service | last_detection: detection_volume, detection_timer: detection_timer}}
		end
	end

	@impl GenServer
	def handle_call(:get_traffic_level, _from, service) do
		{:reply, service.traffic_level, service}
	end

	@impl GenServer
	def handle_cast({:set_traffic_level, level}, service) when level in @traffic_levels do
		service = cancel_detection_timer(service)
		service = %{service | traffic_level: level}

		service =
			case level do
				:none -> service
				_ -> %{service | detection_timer: schedule_next_detection(level)}
			end

		{:noreply, service}
	end

	@impl GenServer
	def handle_cast({:set_traffic_level, _invalid_level}, service) do
		{:noreply, service}
	end

	defp schedule_next_detection(:high), do: Process.send_after(self(), :tick_detection, random_detection_interval_ms(:high))
	defp schedule_next_detection(:low), do: Process.send_after(self(), :tick_detection, random_detection_interval_ms(:low))

	defp cancel_detection_timer(%{detection_timer: nil} = service), do: service

	defp cancel_detection_timer(%{detection_timer: timer_ref} = service) do
		Process.cancel_timer(timer_ref)
		%{service | detection_timer: nil}
	end

	defp random_detection_interval_ms(:low) do
		Enum.random(100..3_000)
	end

	defp random_detection_interval_ms(:high) do
		Enum.random(50..1_000)
	end

	defp random_detection_volume() do
		count = Enum.random(1..10)

		1..count
		|> Enum.reduce(%{}, fn _, acc ->
			type = Enum.random(@vehicle_types)
			Map.update(acc, type, 1, &(&1 + 1))
		end)
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
