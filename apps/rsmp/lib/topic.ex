# A topic paths of the form:
# id/type/module/method/component/...

defmodule RSMP.Topic do
  alias RSMP.Path

  defstruct(
    id: nil,
    type: nil,
    path: Path.new()
  )

  def new(id, type, module, code, component \\ []) do
    %__MODULE__{id: id, type: type, path: Path.new(module, code, component)}
  end

  def component(topic), do: topic.path.component

  def from_string(string) do
    {topic, component} = string |> String.split("/") |> Enum.split(4)

    case topic do
      [id, type, module, code] -> new(id, type, module, code, component)
      [id, type, module] -> new(id, type, module, nil, [])
      [id, type] -> new(id, type, nil, nil, [])
      [id | _] -> new(id, nil, nil, nil, [])
    end
  end

  def to_string(topic) do
    array = [topic.id, topic.type, topic.path.module, topic.path.code] ++ topic.path.component
    array |> Enum.join("/")
  end

  def id_module(topic), do: [topic.id, topic.path.module] |> Enum.join("/")
end
