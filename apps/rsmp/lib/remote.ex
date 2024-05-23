defmodule RSMP.Remote do
  use GenServer
  require Logger

  defstruct(
    id: nil,
    online: false,
    modules: [],
    data: %{}
  )

  def new(options \\ []), do: __struct__(options)

  def start_link({id, remote_id}) do
    via = RSMP.Registry.via(id, :remote, remote_id)
    GenServer.start_link(__MODULE__, remote_id, name: via)
  end

  def get_data(id, remote_id) do
    via = RSMP.Registry.via(id, :remote, remote_id)
    GenServer.call(via, :get_data)
  end

  def get_online_status(id, remote_id) do
    via = RSMP.Registry.via(id, :remote, remote_id)
    GenServer.call(via, :get_online_status)
  end

  def update_online_status(id, remote_id, online_status) do
    via = RSMP.Registry.via(id, :remote, remote_id)
    GenServer.cast(via, {:update_online_status, online_status})
  end

  def update_online_status(pid, online_status) do
    GenServer.cast(pid, {:update_online_status, online_status})
  end

  @impl GenServer
  def init(id) do
    {:ok, new(id: id)}
  end

  @impl GenServer
  def handle_cast({:receive_status, topic, data}, remote) when is_map(data) do
    Logger.info("Receive status #{topic}: #{inspect(data)}")
    index = to_string(topic.path)

    values =
      if remote.data[index] do
        remote.data[index] |> Map.merge(data)
      else
        data
      end

    remote = put_in(remote.data[index], values)
    {:noreply, remote}
  end

  @impl GenServer
  def handle_cast({:receive_status, topic, data}, remote) do
    Logger.warning("Received invalid status #{topic}: must be a map, got #{inspect(data)}")
    {:noreply, remote}
  end

  @impl GenServer
  def handle_cast({:update_online_status, online_status}, remote) do
    was = remote
    remote = %{remote | online: online_status["online"], modules: online_status["modules"]}
    cond do
      remote.online && !was.online ->
        Logger.info("Remote #{remote.id} is online with modules #{inspect(remote.modules)}")
      !remote.online && was.online ->
        Logger.info("Remote #{remote.id} is offline")
      remote.online ->
        Logger.info("Remote #{remote.id} has modules #{inspect(remote.modules)}")
    end
    {:noreply, remote}
  end

  @impl GenServer
  def handle_call(:get_data, _from, remote) do
    {:reply, remote.data, remote}
  end

  @impl GenServer
  def handle_call(:get_online_status, _from, remote) do
    {:reply, Map.take(remote,[:online,:modules]), remote}
  end

end
