defmodule RSMP.Site.TLC do
  use RSMP.Site

  def modules(),
    do: [
      RSMP.Module.TLC,
      RSMP.Module.Traffic
    ]

  def make_site_id do
    "tlc_#{SecureRandom.hex(4)}"
  end

  def setup(site) do
    site |> Map.merge(%{
      statuses: %{
        # signal group status
        "tlc/1" => %{
          base: 0,
          cycle: 0,
          groups: "",
          stage: 0
        },
        # curent signal group plan
        "tlc/14" => %{plan: 1, source: "startup"},
        # signal group plans
        "tlc/22" => [1, 2],
        # offsets
        "tlc/24" => %{1 => 1, 2 => 2},
        # cycle times
        "tlc/28" => %{1 => 6, 2 => 4},
        # number of vehicle
        "traffic/201/dl/1" => %{
          since: RSMP.Time.timestamp(),
          vehicles: 0
        }
      },
      alarms: %{
        # serious hardware error
        "tlc/201/sg/1" => Alarm.new(),
        "tlc/201/sg/2" => Alarm.new(),
        # a301
        "tlc/201/dl/a1" => Alarm.new()
      },
      plans: %{
        1 => %{
          1 => "111efg",
          2 => "abc111"
        },
        2 => %{
          1 => "abc222",
          2 => "222abc"
        }
      }
    })

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
    path = Path.new("tlc","1")
    path_string = Path.to_string(path)
    base = site.statuses[path_string].base
    base = rem(base + 1, cycletime)
    cycle = rem(base + offset, cycletime)
    site = put_in(site.statuses[path_string][:base], base)
    site = put_in(site.statuses[path_string][:cycle], cycle)

    phases =
      for {sg, sg_plan} <- cur_plan(site), into: %{} do
        {sg, String.at(sg_plan, cycle)}
      end

    phase_string = Map.values(phases) |> Enum.join()
    site = put_in(site.statuses[path_string][:groups], phase_string)

    Site.publish_status(site, path)

    pub = %{topic: "status", changes: [path_string]}
    Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", pub)

    site
  end

  # update detector counts
  def detect(site) do
    path = Path.new("traffic","201",["dl","1"])
    path_string = Path.to_string(path)
    now = Time.timestamp()

    site = put_in(site.statuses[path_string][:vehicles], :rand.uniform(3))
    site = put_in(site.statuses[path_string][:since], now)

    Site.publish_status(site, path)

    pub = %{topic: "status", changes: [path_string]}
    Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", pub)

    site
  end

  # helpers

  def cur_plan_nr(site), do: site.statuses["tlc/14"].plan
  def cur_plan(site), do: site.plans[cur_plan_nr(site)]
  def cur_offset(site), do: site.statuses["tlc/24"][cur_plan_nr(site)]
  def cur_cycletime(site), do: site.statuses["tlc/28"][cur_plan_nr(site)]
end
