# A topic paths of the form:
# type/module/code/id/component/... or presence/id

defmodule RSMP.Topic do
  alias RSMP.Path

  defstruct(
    id: nil,
    type: nil,
    path: Path.new()
  )

  def new(id, type, %RSMP.Path{}=path) do
    %__MODULE__{id: id, type: type, path: path}
  end

  def new(id, type, module, code, component \\ []) do
    %__MODULE__{id: id, type: type, path: Path.new(module, code, component)}
  end

  def component(topic), do: topic.path.component

  def from_string(string) do
    parts = String.split(string, "/")

    case parts do
      ["presence", id] ->
        new(id, "presence", nil, nil, [])

      [type, module, code, id | component] ->
        new(id, type, module, code, component)

      _ ->
        new(nil, nil, nil, nil, [])
    end
  end

  def id_module(topic), do: [topic.id, topic.path.module] |> Enum.join("/")

  defimpl String.Chars do
    def to_string(topic) do
      case topic.type do
        "presence" ->
          "presence/#{topic.id}"
        _ ->
          array = [topic.type, topic.path.module, topic.path.code, topic.id] ++ topic.path.component
          array |> Enum.join("/")
      end
    end
  end
end
