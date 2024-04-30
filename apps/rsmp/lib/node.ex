defmodule RSMP.Node do
  use Supervisor

  def start_link(id, children) do
    Supervisor.start_link(__MODULE__, children, name: RSMP.Registry.via(id))
  end

  @impl Supervisor
  def init(children) do
    Supervisor.init(children, strategy: :one_for_one)
  end
end