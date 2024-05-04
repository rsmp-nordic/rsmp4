defmodule RSMP.Commander.TLC do
  @behaviour RSMP.Commander
  require Logger
  # alias RSMP.{Utility, Site, Alarm}

  def converter(), do: RSMP.Converter.TLC

  def receive_result(supervisor, _path, _data, _properties) do
    supervisor
  end

  def receive_status(supervisor, _path, _data, _properties) do
    supervisor
  end

  def receive_alarm(supervisor, _path, _data, _properties) do
    supervisor
  end
end
