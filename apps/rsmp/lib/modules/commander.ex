defmodule RSMP.Commander do
  @type t :: module
  @type supervisor :: RSMP.Supervisor.t()
  @type path :: RSMP.Path.t()
  @type data :: any
  @type properties :: Map

  @callback converter() :: RSMP.Converter

  @callback receive_result(supervisor, path, data, properties) :: supervisor
  @callback receive_status(supervisor, path, data, properties) :: supervisor
  @callback receive_alarm(supervisor, path, data, properties) :: supervisor
end
