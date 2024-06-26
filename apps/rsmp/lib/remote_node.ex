defmodule RSMP.Remote.Node do
  use Supervisor

  def start_link({id, remote_id, services}) do
    Supervisor.start_link(__MODULE__, {id, remote_id, services}, name: RSMP.Registry.via_remote(id, remote_id))
  end

  @impl Supervisor
  def init({id, remote_id, services}) do
    children = [
      {RSMP.Remote.Node.State, {id, remote_id}},
      {RSMP.Remote.Services, {id, remote_id, services}}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end



