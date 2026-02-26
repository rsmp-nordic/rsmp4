# A topic path of the form:
# id/type/code[/channel] or id/type
#
# For status-like topics, the segment after code is the channel name.
# The channel name may be omitted for single-channel statuses.

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

  def new(id, type, code) do
    %__MODULE__{id: id, type: type, path: Path.new(code)}
  end

  def new(id, type, code, channel_name) do
    %__MODULE__{id: id, type: type, channel_name: channel_name, path: Path.new(code)}
  end

  def from_string(string) do
    parts = String.split(string, "/")
    id_levels = Application.get_env(:rsmp, :topic_prefix_levels, 3)

    if length(parts) >= id_levels + 1 do
      {id_parts, rest} = Enum.split(parts, id_levels)
      id = Enum.join(id_parts, "/")

      case rest do
        ["presence"] ->
          new(id, "presence", nil, [])

        # Status-like topics: status, replay, fetch, history, channel, throttle.
        # First segment after code is always channel_name.
        # If there's only id/type/code (no extra segments), channel_name is nil.
        [type, code | tail] when type in ["status", "replay", "fetch", "history", "channel", "throttle"] ->
          case tail do
            [] ->
              # No channel name
              %__MODULE__{id: id, type: type, channel_name: nil, path: Path.new(code)}

            [channel_name | _] ->
              # First segment = channel name
              %__MODULE__{id: id, type: type, channel_name: channel_name, path: Path.new(code)}
          end

        # Non-status topics (command, result, alarm): no channel concept
        [type, code | _tail] ->
          %__MODULE__{id: id, type: type, channel_name: nil, path: Path.new(code)}

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
          Enum.join(parts, "/")
      end
    end
  end
end
