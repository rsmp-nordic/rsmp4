# A topic path of the form:
# id/type/code[/channel][/component] or id/type
#
# For status topics, the first segment after code is always the channel name.
# The channel name can only be omitted when there are no component segments
# (i.e. single-channel statuses with no components).

defmodule RSMP.Topic do
  alias RSMP.Path

  defstruct(
    id: nil,
    type: nil,
    channel_name: nil,
    path: Path.new()
  )

  def new(id, type, %RSMP.Path{} = path) do
    %__MODULE__{id: id, type: type, path: path}
  end

  def new(id, type, code, component \\ []) do
    %__MODULE__{id: id, type: type, path: Path.new(code, component)}
  end

  def new(id, type, code, channel_name, component) do
    %__MODULE__{id: id, type: type, channel_name: channel_name, path: Path.new(code, component)}
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
          new(id, "presence", nil, [])

        # Status-like topics: status, replay, fetch, history, channel.
        # First segment after code is always channel_name.
        # If there's only id/type/code (no extra segments), channel_name is nil.
        [type, code | tail] when type in ["status", "replay", "fetch", "history", "channel"] ->
          case tail do
            [] ->
              # No channel name, no component (single-channel status)
              %__MODULE__{id: id, type: type, channel_name: nil, path: Path.new(code, [])}

            [channel_name | component] ->
              # First segment = channel name, rest = component
              %__MODULE__{id: id, type: type, channel_name: channel_name, path: Path.new(code, component)}
          end

        # Non-status topics (command, result, alarm, throttle): no channel concept
        [type, code | tail] ->
          %__MODULE__{id: id, type: type, channel_name: nil, path: Path.new(code, tail)}

        _ ->
          new(nil, nil, nil, [])
      end
    else
      new(nil, nil, nil, [])
    end
  end

  defimpl String.Chars do
    def to_string(topic) do
      case topic.type do
        "presence" ->
          "#{topic.id}/presence"

        _ ->
          parts = [topic.id, topic.type, topic.path.code]
          parts = if topic.channel_name, do: parts ++ [topic.channel_name], else: parts
          parts = parts ++ topic.path.component

          Enum.join(parts, "/")
      end
    end
  end
end
