defmodule RSMP.Node.TLC do
  @behaviour RSMP.Node.Builder

  def start() do
    RSMP.Node.start(
      services: RSMP.Node.mapping([
        %RSMP.Service.TLC{cycle: 10},
        %RSMP.Service.Traffic{vehicles: 23}
      ])
    )
  end
end