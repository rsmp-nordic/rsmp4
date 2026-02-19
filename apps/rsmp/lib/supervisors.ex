defmodule RSMP.Supervisors do
  use DynamicSupervisor

  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, [], name: RSMP.Registry.via_supervisors())
  end

  @impl DynamicSupervisor
  def init(_init_args) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_supervisor() do
    id = SecureRandom.hex(4)
    spec = {RSMP.Supervisor, id}

    case DynamicSupervisor.start_child(RSMP.Registry.via_supervisors(), spec) do
      {:ok, _pid} ->
        Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisors", %{topic: "supervisors_changed"})
        {:ok, id}

      error ->
        error
    end
  end

  def stop_supervisor(id) do
    result =
      case RSMP.Registry.lookup_supervisor(id) do
        [{pid, _}] -> DynamicSupervisor.terminate_child(RSMP.Registry.via_supervisors(), pid)
        [] -> {:error, :not_found}
      end

    if result == :ok do
      Phoenix.PubSub.broadcast(RSMP.PubSub, "supervisors", %{topic: "supervisors_changed"})
    end

    result
  end

  def list_supervisors() do
    RSMP.Registry.via_supervisors()
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn {_, pid, _, _} ->
      case Registry.keys(RSMP.Registry, pid) do
        [{:supervisor, id}] -> [id]
        _ -> []
      end
    end)
    |> Enum.sort()
  end
end
