defmodule RSMP.Site.Module do
  @type t :: module
  @type site :: RSMP.Site.t()
  @type data :: any

  @callback receive_command(site, Integer, String, data) :: site

  #  @callback send_result(site, Integer, String, data) :: site
  #  @callback send_status(site, Integer, String, data) :: site
  #  @callback send_alarm(site, Integer, String, data) :: site

  #  @callback receive_reaction(site, Integer, String, data) :: site
end
