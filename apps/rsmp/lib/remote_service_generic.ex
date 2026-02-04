defmodule RSMP.Remote.Service.Generic do
  use RSMP.Remote.Service, name: "generic"
  require Logger

  defstruct(
    id: nil,
    data: %{}
  )

  @impl RSMP.Remote.Service.Behaviour
  def new(id, data \\ []), do: __struct__(Map.merge(data, %{id: id}))
end

defimpl RSMP.Remote.Service.Protocol, for: RSMP.Remote.Service.Generic do
  require Logger

  def name(_service), do: "generic"
  def id(service), do: service.id

  def receive_status(
        service,
        %RSMP.Topic{path: path},
        data,
        _properties
      ) do
    Logger.info("RSMP: Received status #{path}: #{inspect(data)}")
    %{service | data: Map.merge(service.data, data)}
  end

  # convert from sxl format to internal format
  def parse_status(_service, _code, data) do
    data
  end

  def receive_alarm(
        service,
        %RSMP.Topic{path: path},
        data,
        _properties
      ) do
    Logger.info("RSMP: Received alarm #{path}: #{inspect(data)}")
    service
  end

  def parse_alarm(_service, _code, data) do
    data
  end
end
