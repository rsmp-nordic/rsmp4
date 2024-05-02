defmodule RSMP.Registry do

  def start_link() do
    {:ok, _} = Registry.start_link(keys: :unique, name: __MODULE__)
  end

  #def register(id,service,module), do: Registry.register(__MODULE__, "#{id}/#{service}", module)
  def lookup(id, service, component) do
    Registry.lookup(__MODULE__,{id, service, component})
  end

  def lookup(id) do
    Registry.lookup(__MODULE__,id)
  end

  #def via(%RSMP.Topic{}=topic), do: {:via, Registry, {__MODULE__, RSMP.Topic.id_module(topic)}}
  def via(id), do: {:via, Registry, {__MODULE__, id}}
  def via(id, service), do: {:via, Registry, {__MODULE__, {id, service}}}
  def via(id, service, component), do: {:via, Registry, {__MODULE__, {id, service, component}}}
end
