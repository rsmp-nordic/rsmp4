# A topic paths of the form:
# id/type/module/code/component/... or id/presence

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
    id_levels = Application.get_env(:rsmp, :topic_prefix_levels, 3)

    if length(parts) >= id_levels + 1 do
      {id_parts, rest} = Enum.split(parts, id_levels)
      id = Enum.join(id_parts, "/")

      case rest do
        ["presence"] ->
          new(id, "presence", nil, nil, [])

        [type, full_code | component] ->
          {module, code} =
            case String.split(full_code, ".", parts: 2) do
              [m, c] -> {m, c}
              [c] -> {nil, c}
            end

          new(id, type, module, code, component)

        _ ->
          new(nil, nil, nil, nil, [])
      end
    else
      new(nil, nil, nil, nil, [])
    end
  end

  def id_module(topic), do: [topic.id, topic.path.module] |> Enum.join("/")

  defimpl String.Chars do
    def to_string(topic) do
      case topic.type do
        "presence" ->
          "#{topic.id}/presence"

        _ ->
          path = topic.path
          code_str = if path.module, do: "#{path.module}.#{path.code}", else: path.code
          array = [topic.id, topic.type, code_str] ++ path.component
          array |> Enum.join("/")
      end
    end
  end
end
