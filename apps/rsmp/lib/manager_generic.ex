defmodule RSMP.Manager.Generic do
  use RSMP.Manager, name: "generic"
  require Logger

  defstruct(
    id: nil,
    data: %{}
  )

  @impl RSMP.Manager.Behaviour
  def new(id, data \\ []), do: __struct__(Map.merge(data, %{id: id}))
end

defimpl RSMP.Manager.Protocol, for: RSMP.Manager.Generic do
  require Logger

  def name(_service), do: "generic"
  def id(service), do: service.id

  def receive_status(
        service,
        %RSMP.Topic{path: path},
        data,
        _properties
      ) do
    Logger.debug("RSMP: Received status #{path}: #{inspect(data)}")
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
    Logger.debug("RSMP: Received alarm #{path}: #{inspect(data)}")
    service
  end

  def parse_alarm(_service, _code, data) do
    data
  end
end
