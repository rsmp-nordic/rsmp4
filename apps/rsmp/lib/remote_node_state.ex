
defmodule RSMP.Remote.Node.State do
  use GenServer
  require Logger

  defstruct(
    id: nil,
    remote_id: nil,
    type: nil,
    online: false,
    modules: []
  )

  def new(options \\ []), do: __struct__(options)

  def start_link({id, remote_id}) do
    via = RSMP.Registry.via_remote_state(id, remote_id)
    GenServer.start_link(__MODULE__, {id, remote_id}, name: via)
  end

  def get_online_status(id, remote_id) do
    via = RSMP.Registry.via_remote_state(id, remote_id)
    GenServer.call(via, :get_online_status)
  end

  def update_online_status(id, remote_id, online_status) do
    via = RSMP.Registry.via_remote_state(id, remote_id)
    GenServer.cast(via, {:update_online_status, online_status})
  end

  def update_online_status(pid, online_status) do
    GenServer.cast(pid, {:update_online_status, online_status})
  end

  @impl GenServer
  def init({id, remote_id}) do
    {:ok, new(id: id, remote_id: remote_id)}
  end

  @impl GenServer
  def handle_cast({:update_online_status, status}, remote) when is_binary(status) do
    online = status == "online"
    remote = %{remote | online: online}

    if remote.online do
      Logger.info("Remote #{remote.remote_id} is online")
    else
      Logger.info("Remote #{remote.remote_id} is offline: #{status}")
    end
    {:noreply, remote}
  end

  def handle_cast({:update_online_status, online_status}, remote) when is_map(online_status) do
    remote = %{remote | type: online_status["type"], online: online_status["online"], modules: online_status["modules"]}
    if remote.online do
      Logger.info("Remote #{remote.remote_id} is online with type '#{remote.type}' and modules #{inspect(remote.modules)}")
    else
      Logger.info("Remote #{remote.remote_id} is offline")
    end
    {:noreply, remote}
  end

  @impl GenServer
  def handle_call(:get_online_status, _from, remote) do
    {:reply, Map.take(remote,[:online,:modules]), remote}
  end
end
