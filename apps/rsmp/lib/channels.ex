defmodule RSMP.Channels do
  @moduledoc """
  DynamicSupervisor for channel processes belonging to a node.
  """
  use DynamicSupervisor

  def start_link(id) do
    DynamicSupervisor.start_link(__MODULE__, id, name: RSMP.Registry.via_channels(id))
  end

  @impl DynamicSupervisor
  def init(_id) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Start a channel under this supervisor."
  def start_channel(id, %RSMP.Channel.Config{} = config) do
    via = RSMP.Registry.via_channels(id)
    DynamicSupervisor.start_child(via, {RSMP.Channel, {id, config}})
  end

  @doc "List all channel pids for a node."
  def list_channels(id) do
    match_pattern = {{{id, :channel, :_, :_}, :"$1", :_}, [], [:"$1"]}
    Registry.select(RSMP.Registry, [match_pattern])
  end

  @doc "Get info for all channels of a node."
  def list_channel_info(id) do
    list_channels(id)
    |> Enum.map(fn pid -> RSMP.Channel.info(pid) end)
  end
end
