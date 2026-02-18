# A topic path of the form:
# id/type/code[/stream][/component] or id/type
#
# For status topics, the first segment after code is always the stream name.
# The stream name can only be omitted when there are no component segments
# (i.e. single-stream statuses with no components).

defmodule RSMP.Topic do
  alias RSMP.Path

  defstruct(
    id: nil,
    type: nil,
    stream_name: nil,
    path: Path.new()
  )

  def new(id, type, %RSMP.Path{} = path) do
    %__MODULE__{id: id, type: type, path: path}
  end

  def new(id, type, module, code, component \\ []) do
    %__MODULE__{id: id, type: type, path: Path.new(module, code, component)}
  end

  def new(id, type, module, code, stream_name, component) do
    %__MODULE__{id: id, type: type, stream_name: stream_name, path: Path.new(module, code, component)}
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

        # Status topics: first segment after code is always stream_name.
        # If there's only id/type/code (no extra segments), stream_name is nil.
        ["status", full_code | tail] ->
          {module, code} =
            case String.split(full_code, ".", parts: 2) do
              [m, c] -> {m, c}
              [c] -> {nil, c}
            end

          case tail do
            [] ->
              # No stream name, no component (single-stream status)
              %__MODULE__{id: id, type: "status", stream_name: nil, path: Path.new(module, code, [])}

            [stream_name | component] ->
              # First segment = stream name, rest = component
              %__MODULE__{id: id, type: "status", stream_name: stream_name, path: Path.new(module, code, component)}
          end

        # Non-status topics (command, result, alarm): no stream concept
        [type, full_code | tail] ->
          {module, code} =
            case String.split(full_code, ".", parts: 2) do
              [m, c] -> {m, c}
              [c] -> {nil, c}
            end

          %__MODULE__{id: id, type: type, stream_name: nil, path: Path.new(module, code, tail)}

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

          parts = [topic.id, topic.type, code_str]
          parts = if topic.stream_name, do: parts ++ [topic.stream_name], else: parts
          parts = parts ++ path.component

          Enum.join(parts, "/")
      end
    end
  end
end
