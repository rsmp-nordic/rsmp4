defmodule RSMP.Path do
  defstruct [:module, :code, component: []]

  def new() do
    %__MODULE__{}
  end

  def new(module, code, component \\ []) do
    %__MODULE__{module: module, code: code, component: component}
  end

  def to_list(path) do
    [path.module, path.code] ++ path.component
  end

  def from_string(string) do
    {[module, code], component} = string |> String.split("/") |> Enum.split(2)
    new(module, code, component)
  end

  def to_string(path) do
    array = [path.module, path.code] ++ path.component
    array |> Enum.join("/")
  end
end
