defmodule RSMP.Utility do
  # helpers

  def client_options do
    Application.get_env(:rsmp, :emqtt) |> Enum.into(%{})
  end

  # Parse topic paths of the form:
  # id/type/module/method/component/...
  #
  # Component can have 0 (ie. left out), 1 or more levels, so all these are valid:
  #
  # 563f36a/command/sys/version
  # 563f36a/command/sys/version/sg
  # 563f36a/command/sys/version/sg/1
  #
  # We first split by "/".
  # The first is our id, the next 2 elements (type, module, method) is the path.
  # The rest is the component path, which can be have 0, 1 or more elements.
  #
  def parse_topic(topic) do
    topic = String.split(topic, "/", trim: true)
    # optionally remove id
    [_id | topic] = topic
    Enum.split(topic, 3)
  end

  # Parse topic paths of the form:
  # module/method/component/...
  def parse_path(topic) do
    topic = String.split(topic, "/", trim: true)
    # optionally remove id
    Enum.split(topic, 2)
  end

  def to_payload(data) do
    Poison.encode!(data)
    # Logger.info "Encoded #{data} to JSON: #{inspect(json)}"
  end

  def from_payload(json) do
    try do
      Poison.decode!(json)
    rescue
      _e ->
        # Logger.warning "Could not decode JSON: #{inspect(json)}"
        nil
    end
  end

  def build_path(module, command, component) do
    [module, command, component]
    |> List.flatten()
    |> Enum.join("/")
  end

  def map_paths(map, path \\ []) do
    Enum.flat_map(map, fn {key, value} ->
      new_path = path ++ [key]

      if is_map(value) do
        map_paths(value, new_path)
      else
        {path, value}
      end
    end)
  end

  def now() do
    DateTime.truncate(DateTime.utc_now(), :millisecond)
  end

  def timestamp(time \\ now()) do
    Calendar.strftime(time, "%xT%X.%fZ")
  end
end