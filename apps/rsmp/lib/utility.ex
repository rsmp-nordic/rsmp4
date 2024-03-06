defmodule RSMP.Utility do
  # helpers
  require Logger

  def client_options do
    Application.get_env(:rsmp, :emqtt) |> Enum.into(%{})
  end

  def to_payload(data) do
    cbor = CBOR.encode(data) # CBOR
    #cbor_size = byte_size(cbor)

    #json = Poison.encode!(data) # JSON
    #json_size = byte_size(json)

    # Logger.info "Encoded #{data} to JSON: #{inspect(json)}"
    #saved = round((1-cbor_size/json_size)*100)
    #Logger.info("json: #{json_size}, cbor: #{cbor_size}, saved #{saved}%")
    cbor
  end

  def from_payload(data) do
    try do
      {:ok, result, ""=_rest} = CBOR.decode(data)
      result
      #Poison.decode!(binary) # JSON
    rescue
      _e ->
        # Logger.warning "Could not decode: #{inspect(data)}"
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
