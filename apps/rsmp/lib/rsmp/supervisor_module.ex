defmodule RSMP.Supervisor.Module do
  @type t :: module
  @type supervisor :: RSMP.Supervisor.t()
  @type data :: any

  @callback send_command(supervisor, Integer, data) :: supervisor
  @callback receive_result(supervisor, Integer, data) :: supervisor

  @callback receive_status(supervisor, Integer, data) :: supervisor

  @callback receive_alarm(supervisor, Integer, data) :: supervisor
  @callback send_reaction(supervisor, Integer, data) :: supervisor
end
