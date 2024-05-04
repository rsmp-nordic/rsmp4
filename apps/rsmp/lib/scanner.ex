defmodule RSMP.Scanner do
  use GenServer
  require Logger
 
  defstruct [:id]

  def start_link(id) do
    via = RSMP.Registry.via(:helper, id, __MODULE__)
    GenServer.start_link(__MODULE__, id, name: via)
  end

  @impl GenServer
  def init(id) do
    Logger.info("RSMP: starting scanner")
    scanner = %__MODULE__{id: id}
    {:ok, scanner}
  end

  @impl GenServer
  def handle_cast({:receive_state, topic, data}, scanner) do
    case RSMP.Registry.lookup(:remote, scanner.id, topic.id) do
      [] ->
        Logger.info("Adding remote for #{topic.id} with modules: #{inspect(data["modules"])}")
        via = RSMP.Registry.via(:helper, scanner.id, RSMP.RemoteSupervisor)
        {:ok, _pid} = DynamicSupervisor.start_child(via, {RSMP.Remote, {scanner.id, topic.id}})
      [{_pid, _}] ->
        Logger.info("Updating remote for #{topic.id} with modules: #{inspect(data["modules"])}")        
    end

    {:noreply, scanner}
  end
end
