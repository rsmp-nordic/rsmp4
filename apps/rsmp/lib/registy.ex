defmodule RSMP.Registry do
  def start_link() do
    {:ok, _} = Registry.start_link(keys: :unique, name: __MODULE__)
  end

  def register(:helper, id, type) do
    Registry.register(__MODULE__, {:helper, id, type}, nil)
  end

  def lookup(:service, id, service, component) do
    Registry.lookup(__MODULE__, {:service, id, service, component})
  end

  def lookup(:remote, id, remote_id) do
    Registry.lookup(__MODULE__, {:remote, id, remote_id})
  end

  def lookup(:helper, id, type) do
    Registry.lookup(__MODULE__, {:helper, id, type})
  end

  # def via(%RSMP.Topic{}=topic), do: {:via, Registry, {__MODULE__, RSMP.Topic.id_module(topic)}}
  def via(:node, id), do: {:via, Registry, {__MODULE__, {:node, id}}}
  def via(:remote, id, remote_id), do: {:via, Registry, {__MODULE__, {:remote, id, remote_id}}}
  def via(:helper, id, service), do: {:via, Registry, {__MODULE__, {:helper, id, service}}}

  def via(:service, id, service, component),
    do: {:via, Registry, {__MODULE__, {:service, id, service, component}}}
end
