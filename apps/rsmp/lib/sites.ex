defmodule RSMP.Sites do
  use DynamicSupervisor

  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, [], name: RSMP.Registry.via_sites())
  end

  @impl DynamicSupervisor
  def init(_init_args) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_site() do
    id = RSMP.Node.TLC.make_site_id()
    start_site_with_id(id)
  end

  def start_site_with_id(id) do
    spec = {RSMP.Node.TLC, id}

    case DynamicSupervisor.start_child(RSMP.Registry.via_sites(), spec) do
      {:ok, _pid} ->
        Phoenix.PubSub.broadcast(RSMP.PubSub, "sites", %{topic: "sites_changed"})
        {:ok, id}

      error ->
        error
    end
  end

  def ensure_site(id) do
    case RSMP.Registry.lookup_node(id) do
      [{_pid, _}] -> {:ok, id}
      [] -> start_site_with_id(id)
    end
  end

  def stop_site(id) do
    case RSMP.Registry.lookup_node(id) do
      [{pid, _}] ->
        result = DynamicSupervisor.terminate_child(RSMP.Registry.via_sites(), pid)

        if result == :ok do
          Phoenix.PubSub.broadcast(RSMP.PubSub, "sites", %{topic: "sites_changed"})
        end

        result

      [] ->
        {:error, :not_found}
    end
  end

  def list_sites() do
    RSMP.Registry.via_sites()
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn {_, pid, _, _} ->
      case Registry.keys(RSMP.Registry, pid) do
        [{id, :node}] -> [id]
        _ -> []
      end
    end)
    |> Enum.sort()
  end
end
