defmodule RSMP.Responder do
  @type t :: module
  @type site :: RSMP.Site.t()
  @type data :: any

  @callback receive_command(site, String, String, data) :: site
  @callback receive_reaction(site, String, String, data) :: site
end
