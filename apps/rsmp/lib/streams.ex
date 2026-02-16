defmodule RSMP.Streams do
  @moduledoc """
  DynamicSupervisor for stream processes belonging to a node.
  """
  use DynamicSupervisor

  def start_link(id) do
    DynamicSupervisor.start_link(__MODULE__, id, name: RSMP.Registry.via_streams(id))
  end

  @impl DynamicSupervisor
  def init(_id) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Start a stream under this supervisor."
  def start_stream(id, module, %RSMP.Stream.Config{} = config) do
    via = RSMP.Registry.via_streams(id)
    DynamicSupervisor.start_child(via, {RSMP.Stream, {id, module, config}})
  end

  @doc "List all stream pids for a node."
  def list_streams(id) do
    match_pattern = {{{id, :stream, :_, :_, :_, :_}, :"$1", :_}, [], [:"$1"]}
    Registry.select(RSMP.Registry, [match_pattern])
  end

  @doc "Get info for all streams of a node."
  def list_stream_info(id) do
    list_streams(id)
    |> Enum.map(fn pid -> RSMP.Stream.info(pid) end)
  end
end
