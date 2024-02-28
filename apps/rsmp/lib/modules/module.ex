defmodule RSMP.Module do
  @callback name() :: String
  @callback converter() :: RSMP.Converter
  @callback commander() :: RSMP.Commander
  @callback responder() :: RSMP.Responder
end
