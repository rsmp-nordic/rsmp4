defmodule RSMP.Utility do
  # helpers

  def client_options do
    Application.get_env(:rsmp, :emqtt) |> Enum.into(%{})
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
end
