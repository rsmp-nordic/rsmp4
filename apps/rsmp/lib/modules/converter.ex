defmodule RSMP.Converter do
  @type data :: Map
  @type code :: String

  @callback to_rsmp_status(code, data) :: data
  @callback from_rsmp_status(code, data) :: data
end
