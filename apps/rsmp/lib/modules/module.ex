defmodule RSMP.Module do
  #@callback init() :: Map
  @callback converter() :: RSMP.Converter  
  @callback commander() :: RSMP.Commander  
  @callback responder() :: RSMP.Responder  
end
