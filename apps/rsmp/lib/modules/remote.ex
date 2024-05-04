defmodule RSMP.Remote do
  use GenServer
  require Logger

  defstruct(
    data: %{}
  )

  def new(options \\ []), do: __struct__(options)

  def start_link({id, remote_id}) do
    via = RSMP.Registry.via(:remote, id, remote_id)
    GenServer.start_link(__MODULE__, remote_id, name: via)
  end

  @impl GenServer
  def init(_remote_id) do
    {:ok, new()}
  end

  @impl GenServer
  def handle_cast({:receive_status, topic, data}, remote) when is_map(data) do
    Logger.warning("Receive status #{RSMP.Topic.to_string(topic)}: #{inspect(data)}")
    IO.inspect(remote)
    index = RSMP.Path.to_string(topic.path)
    values = if remote.data[index] do
      remote.data[index] |> Map.merge(data)
    else
      data
    end
    remote = put_in(remote.data[index],values)
    IO.inspect(remote.data)
    {:noreply, remote}
  end

  @impl GenServer
  def handle_cast({:receive_status, topic, data}, remote)  do
    Logger.warning("Received invalid status #{RSMP.Topic.to_string(topic)}: must be a map, got #{inspect(data)}")
    {:noreply, remote}
  end
end
