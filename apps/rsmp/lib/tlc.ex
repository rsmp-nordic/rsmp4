defmodule RSMP.Node.TLC do

  def start_link(id) do
    children = [
      Supervisor.child_spec({RSMP.Service.TLC, {id,"tlc1",%{plan: 1}}}, id: "tlc1"),
      Supervisor.child_spec({RSMP.Service.TLC, {id,"tlc2",%{plan: 2}}}, id: "tlc2")
    ]
    RSMP.Node.start_link(id, children)
  end
end