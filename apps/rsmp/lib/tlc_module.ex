defmodule RSMP.Module.TLC do
  # @behaviour RSMP.Module

  def name(), do: "tlc"
  def codes(), do: RSMP.Service.TLC.status_codes() ++ RSMP.Service.TLC.alarm_codes() ++ RSMP.Service.TLC.command_codes()
  def converter(), do: RSMP.Converter.TLC
  def commander(), do: RSMP.Commander.TLC
  def responder(), do: RSMP.Responder.TLC
  def manager(), do: RSMP.Remote.Service.TLC
end
