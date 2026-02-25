defmodule RSMP.Path do
  defstruct [:code, component: []]

  def new() do
    %__MODULE__{}
  end

  def new(code, component \\ []) do
    %__MODULE__{code: code, component: component}
  end

  def from_string(string) do
    {code, component} =
      case String.split(string, "/", parts: 2) do
        [code, rest] -> {code, String.split(rest, "/")}
        [code] -> {code, []}
      end

    new(code, component)
  end

  def component_string(path), do: path.component |> Enum.join("/")

  defimpl String.Chars do
    def to_string(path) do
      if path.component == [] do
        path.code
      else
        Enum.join([path.code | path.component], "/")
      end
    end
  end
end
