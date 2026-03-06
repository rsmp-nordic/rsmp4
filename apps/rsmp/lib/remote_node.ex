defmodule RSMP.Remote.Node do
  use Supervisor

  def start_link({id, remote_id, services}) do
    start_link({id, remote_id, services, []})
  end

  def start_link({id, remote_id, services, options}) do
    Supervisor.start_link(__MODULE__, {id, remote_id, services, options}, name: RSMP.Registry.via_remote(id, remote_id))
  end

  @impl Supervisor
  def init({id, remote_id, services, options}) do
    site_data_children =
      if Keyword.get(options, :type) == :supervisor do
        initial_presence = Keyword.get(options, :initial_presence, "offline")
        [{RSMP.Remote.SiteData, {id, remote_id, initial_presence}}]
      else
        []
      end

    children = [
      {RSMP.Remote.Node.State, {id, remote_id}},
      {RSMP.Managers, {id, remote_id, services}}
    ] ++ site_data_children

    Supervisor.init(children, strategy: :one_for_one)
  end
end
