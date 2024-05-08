defmodule RSMP.Registry do
  def start_link(), do: {:ok, _} = Registry.start_link(keys: :unique, name: __MODULE__)

  def lookup(id, type), do: Registry.lookup(__MODULE__, {id, type})
  def lookup(id, type, which), do: Registry.lookup(__MODULE__, {id, type, which})

  def lookup(id, :service, service, component) do
    Registry.lookup(__MODULE__, {id, :service, service, component})
  end

  def via(id, type), do: {:via, Registry, {__MODULE__, {id, type}}}
  def via(id, type, which), do: {:via, Registry, {__MODULE__, {id, type, which}}}

  def via(id, :service, service, component),
    do: {:via, Registry, {__MODULE__, {id, :service, service, component}}}
end
