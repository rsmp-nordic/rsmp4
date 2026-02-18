defmodule RSMP.ButtonClasses do
  @base "text-white rounded-lg px-2"

  def neutral(opts \\ []) when is_list(opts) do
    hover = Keyword.get(opts, :hover, false)
    dimmed = Keyword.get(opts, :dimmed, false)

    [
      @base,
      "bg-stone-600",
      if(hover, do: "hover:bg-orange-600"),
      if(dimmed, do: "bg-stone-400"),
      if(dimmed, do: "text-white/70")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  def selectable(selected) when is_boolean(selected) do
    state(selected, dimmed: not selected, hover_inactive: true)
  end

  def stream(running) when is_boolean(running) do
    state(running, dimmed: not running)
  end

  def alarm(set, dimmed) when is_boolean(set) and is_boolean(dimmed) do
    state(set, dimmed: dimmed)
  end

  def state(active, opts \\ []) when is_boolean(active) and is_list(opts) do
    dimmed = Keyword.get(opts, :dimmed, false)
    hover_inactive = Keyword.get(opts, :hover_inactive, false)

    [
      @base,
      if(active, do: "bg-purple-900", else: "bg-stone-600"),
      if(not active and hover_inactive, do: "hover:bg-orange-600"),
      if(dimmed and active, do: "bg-purple-300"),
      if(dimmed and not active, do: "bg-stone-400"),
      if(dimmed, do: "text-white/70")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end
end
