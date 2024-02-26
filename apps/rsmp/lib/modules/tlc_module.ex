defmodule RSMP.Module.TLC do
  @behaviour RSMP.Module

  def converter(), do: RSMP.Converter.TLC
  def commander(), do: RSMP.Commander.TLC  
  def responder(), do: RSMP.Responder.TLC
end
