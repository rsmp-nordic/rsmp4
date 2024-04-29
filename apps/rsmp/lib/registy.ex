defmodule RSMP.Registry do

  def start_link() do
    {:ok, _} = Registry.start_link(keys: :unique, name: __MODULE__)
  end

  #def register(id,service,module), do: Registry.register(__MODULE__, "#{id}/#{service}", module)
  def lookup(id,service) do
    [{pid,_value}] = Registry.lookup(RSMP.Registry,"#{id}/#{service}")
    pid
  end

  def via(%RSMP.Topic{}=topic), do: {:via, Registry, {__MODULE__, RSMP.Topic.id_module(topic)}}
  def via(id,service), do: {:via, Registry, {__MODULE__, "#{id}/#{service}"}}
end
