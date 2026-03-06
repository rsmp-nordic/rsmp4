defmodule RSMP.Module.Traffic do
  # @behaviour RSMP.Module

  def name(), do: "traffic"
  def codes(), do: RSMP.Service.Traffic.status_codes() ++ RSMP.Service.Traffic.alarm_codes() ++ RSMP.Service.Traffic.command_codes()
  def converter(), do: RSMP.Converter.Traffic
  def manager(), do: RSMP.Manager.Generic
end
