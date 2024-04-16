defmodule RSMP.Service.Traffic do
  defstruct(
    since: "yesterday",
    vehicles: 0
  )
  defimpl RSMP.Service.Protocol, for: __MODULE__ do
    def name(_service), do: "traffic"
    def status(service, "since"), do: service.since
    def status(service, "vehicles"), do: service.vehicles
  def ingoing(service, _code, _args), do: service
  end
end
