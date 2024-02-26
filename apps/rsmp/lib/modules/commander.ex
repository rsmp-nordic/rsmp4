defmodule RSMP.Commander do
  @type t :: module
  @type supervisor :: RSMP.Supervisor.t()
  @type data :: any

  @callback converter() :: RSMP.Converter

  @callback receive_result(supervisor, Integer, data) :: supervisor
  @callback receive_status(supervisor, Integer, data) :: supervisor
  @callback receive_alarm(supervisor, Integer, data) :: supervisor
end
