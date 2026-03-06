defmodule RSMP.Module.TLC do
  # @behaviour RSMP.Module

  def name(), do: "tlc"
  def codes(), do: RSMP.Service.TLC.status_codes() ++ RSMP.Service.TLC.alarm_codes() ++ RSMP.Service.TLC.command_codes()
  def converter(), do: RSMP.Converter.TLC
  def manager(), do: RSMP.Manager.TLC
end
