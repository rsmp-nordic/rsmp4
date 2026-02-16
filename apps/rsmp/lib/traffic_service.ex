defmodule RSMP.Service.Traffic do
	use RSMP.Service, name: "traffic"

	@vehicle_types ["cars", "bicycles", "busses"]
	@zero_volume %{"cars" => 0, "bicycles" => 0, "busses" => 0}

	@impl true
	def status_codes(), do: ["volume"]

	@impl true
	def alarm_codes(), do: []

	defstruct(
		id: nil,
		live_volume: @zero_volume
	)

	@impl RSMP.Service.Behaviour
	def new(id, _data \\ %{}) do
		Process.send_after(self(), :tick_detection, random_detection_interval_ms())

		%__MODULE__{id: id}
	end

	@impl GenServer
	def handle_info(:tick_detection, service) do
		detection_volume = random_detection_volume()
		live_volume = accumulate_volume(service.live_volume, detection_volume)

		live_update =
			Enum.into(detection_volume, %{}, fn {type, _count} ->
				{type, Map.fetch!(live_volume, type)}
			end)

		RSMP.Service.report_to_streams(service.id, "traffic", "volume", live_update)

		Process.send_after(self(), :tick_detection, random_detection_interval_ms())

		{:noreply, %{service | live_volume: live_volume}}
	end

	defp random_detection_interval_ms() do
		Enum.random(100..3_000)
	end

	defp accumulate_volume(current, delta) do
		Map.merge(current, delta, fn _key, current_count, delta_count ->
			current_count + delta_count
		end)
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
	def receive_reaction(service, _topic, _data, _properties), do: service

	def format_status(service, "volume") do
		service.live_volume
	end
end
