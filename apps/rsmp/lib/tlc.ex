defmodule RSMP.Node.TLC do
end

defimpl RSMP.Node.Builder, for: RSMP.Node.TLC do    
  def name(), do: "tlc"
  def services(), do: [RSMP.Service.TLC,RSMP.Service.Traffic]
  def managers(), do: []
  def start()
end
