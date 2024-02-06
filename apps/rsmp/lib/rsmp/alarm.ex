defmodule RSMP.Alarm do
  defstruct(
    active: false,
    acknowledge: false,
    blocked: true
  )

  def new(options \\ []), do: __struct__(options)

  def get_flag_keys() do
    [:active, :acknowledge, :blocked] |> Enum.sort()
  end

  def flag_atom_from_string(flag) do
    mapping = %{
      "active" => :active,
      "acknowledged" => :acknowledged,
      "blocked" => :blocked
    }

    mapping[flag]
  end

  def get_flag(alarm, flag) do
    Map.get(alarm, flag)
  end

  def set_flag(alarm, flag, value) do
    Map.put(alarm, flag, value)
  end

  def flag_on(alarm, flag) do
    Map.put(alarm, flag, true)
  end

  def flag_off(alarm, flag) do
    Map.put(alarm, flag, false)
  end

  def toggle_flag(alarm, flag) do
    Map.put(alarm, flag, Map.get(alarm, flag) == false)
  end

  def active?(alarm) do
    Map.get(alarm, :active) == true
  end
end
