defmodule RSMP.Commander.TLC do
  @behaviour RSMP.Commander
  require Logger
  alias RSMP.{Utility,Site,Alarm}
  
  def converter(), do: RSMP.Converter.TLC

  def receive_result(supervisor, Integer, data) do
  end

  def receive_status(supervisor, Integer, data) do
  end

  def receive_alarm(supervisor, Integer, data) do
  end
end
