defmodule RSMP.Registry do
  def start_link(), do: {:ok, _} = Registry.start_link(keys: :unique, name: __MODULE__)

  def via(key), do: {:via, Registry, {__MODULE__, key}}
  def via_connection(id), do: via({id, :connection})
  def via_node(id), do: via({id, :node})
  def via_services(id), do: via({id, :services})
  def via_service(id, module, component), do: via({id, :service, module, component})
  def via_remotes(id), do: via({id, :remotes})
  def via_remote(id, remote_id), do: via({id, :remote, remote_id})
  def via_remote_state(id, remote_id), do: via({id, :remote_state, remote_id})
  def via_remote_services(id, remote_id), do: via({id, :remote_services, remote_id})
  def via_remote_service(id, remote_id, module, component), do: via({id, :remote_service, remote_id, module, component})
    #type = List.first(component)
    
  def lookup(key), do: Registry.lookup(__MODULE__, key)
  def lookup_connection(id), do: lookup({id, :connection})
  def lookup_node(id), do: lookup({id, :node})
  def lookup_services(id), do: lookup({id, :services})
  def lookup_service(id, module, component), do: lookup({id, :service, module, component})
  def lookup_remotes(id), do: lookup({id, :remotes})
  def lookup_remote(id, remote_id), do: lookup({id, :remote, remote_id})
  def lookup_remote_state(id, remote_id), do: lookup({id, :remote_state, remote_id})
  def lookup_remote_services(id, remote_id), do: lookup({id, :remote_services, remote_id})
  def lookup_remote_service(id, remote_id, module, component), do: lookup({id, :remote_service, remote_id, module, component})
end
