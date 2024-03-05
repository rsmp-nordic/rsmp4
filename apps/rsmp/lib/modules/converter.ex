defmodule RSMP.Converter do
  @type data :: Map
  @type code :: String
  @type statuses :: Map

  @callback to_rsmp_status(code, data) :: data
  @callback from_rsmp_status(code, data) :: data
  @callback command_default(code, statuses) :: data
end
