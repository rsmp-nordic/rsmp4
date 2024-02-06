defmodule Client do
  defmacro __using__(_options) do
    quote do
      def greet(), do: "Hello from #{name()}"
    end
  end
end

defmodule TLC do
  use Client
  def name(), do: "TLC"
end
