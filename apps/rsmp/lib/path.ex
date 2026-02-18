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
    {full_code, component} =
      case String.split(string, "/", parts: 2) do
        [full_code, rest] -> {full_code, String.split(rest, "/")}
        [full_code] -> {full_code, []}
      end

    {module, code} =
      case String.split(full_code, ".", parts: 2) do
        [m, c] -> {m, c}
        [c] -> {nil, c}
      end

    new(module, code, component)
  end

  def component_string(path), do: path.component |> Enum.join("/")

  defimpl String.Chars do
    def to_string(path) do
      code_part = if path.module, do: "#{path.module}.#{path.code}", else: path.code

      if path.component == [] do
        code_part
      else
        Enum.join([code_part | path.component], "/")
      end
    end
  end
end
