defmodule RSMP.Site.TLC do
  use RSMP.Site

  def modules(),
    do: [
      RSMP.Module.TLC,
      RSMP.Module.Traffic
    ]

  def client_id do
    "tlc_#{SecureRandom.hex(4)}"
  end

  def setup(site) do
    site
  end

  def continue_client() do
    Process.send_after(self(), :tick, 1000)
  end

  def handle_info(:tick, site) do
    site =
      site
      |> cycle()
      |> detect()

    Process.send_after(self(), :tick, 1000)
    {:noreply, site}
  end

  # move cycle counter and update signal group status
  def cycle(site) do
    cycletime = cur_cycletime(site)
    offset = cur_offset(site)
    signal_group_status_path = "tlc/1"
    base = site.statuses[signal_group_status_path].base
    base = rem(base + 1, cycletime)
    cycle = rem(base + offset, cycletime)
    site = put_in(site, [:statuses, signal_group_status_path, :base], base)
    site = put_in(site, [:statuses, signal_group_status_path, :cycle], cycle)

    phases =
      for {sg, sg_plan} <- cur_plan(site), into: %{} do
        {sg, String.at(sg_plan, cycle)}
      end

    phase_string = Map.values(phases) |> Enum.join()
    site = put_in(site, [:statuses, signal_group_status_path, :groups], phase_string)

    Site.publish_status(site, signal_group_status_path)

    data = %{topic: "status", changes: [signal_group_status_path]}
    Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", data)

    site
  end

  # update detector counts
  def detect(site) do
    counts_path = "traffic/201/dl/1"
    now = Time.timestamp()

    site = site |> put_in([:statuses, counts_path, :vehicles], :rand.uniform(3))
    site = site |> put_in([:statuses, counts_path, :starttime], now)

    Site.publish_status(site, counts_path)

    data = %{topic: "status", changes: [counts_path]}
    Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", data)

    site
  end

  # helpers

  def cur_plan_nr(site), do: site.statuses["tlc/14"].plan
  def cur_plan(site), do: site.plans[cur_plan_nr(site)]
  def cur_offset(site), do: site.statuses["tlc/24"][cur_plan_nr(site)]
  def cur_cycletime(site), do: site.statuses["tlc/28"][cur_plan_nr(site)]
end
