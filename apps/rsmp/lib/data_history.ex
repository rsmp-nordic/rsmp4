defmodule RSMP.DataHistory do
  @moduledoc """
  Capped ring-buffer for history lists.
  """

  @doc """
  Appends `entry` to `history` and trims to at most `max` entries (keeping the newest).
  """
  def push(history, entry, max \\ 3600) do
    Enum.take(history ++ [entry], -max)
  end
end
