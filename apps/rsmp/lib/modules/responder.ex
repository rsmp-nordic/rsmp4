defmodule RSMP.Responder do
  @type t :: module
  @type site :: RSMP.Site.t()
  @type path :: RSMP.Path.t()
  @type component :: List
  @type data :: any
  @type properties :: Map


  @callback receive_command(site, path, data, properties) :: site
  @callback receive_reaction(site, path, data, properties) :: site
end
