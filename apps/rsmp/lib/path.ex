defmodule RSMP.Path do
  defstruct [:code]

  def new() do
    %__MODULE__{}
  end

  def new(code) do
    %__MODULE__{code: code}
  end

  def from_string(string) do
    %__MODULE__{code: string}
  end

  defimpl String.Chars do
    def to_string(path) do
      path.code
    end
  end
end
