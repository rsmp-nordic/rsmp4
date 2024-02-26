defmodule RSMP.Site.TLC do
  use RSMP.Site

  def client_id do
    "tlc_#{SecureRandom.hex(4)}"
  end

  def init_client(client) do
    client
    |> Map.merge(%{
      modules: %{
        "tlc" => RSMP.Responder.TLC,
        "traffic" => RSMP.Responder.Traffic
      },
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
          starttime: timestamp(),
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
          1 => "111nbb",
          2 => "11nbbb"
        },
        2 => %{
          1 => "eeffff",
          2 => "gggghh"
        }
      }
    })
  end

  def continue_client() do
    #Process.send_after(self(), :tick, 1000)
  end

  def handle_info(:tick, client) do
    client =
      client
      |> cycle()
      |> detect()

    Process.send_after(self(), :tick, 1000)
    {:noreply, client}
  end

  # move cycle counter and update signal group status
  def cycle(client) do
    cycletime = cur_cycletime(client)
    offset = cur_offset(client)
    signal_group_status_path = "tlc/1"
    base = client.statuses[signal_group_status_path].base
    base = rem(base + 1, cycletime)
    cycle = rem(base + offset, cycletime)
    client = put_in(client, [:statuses, signal_group_status_path, :base], base)
    client = put_in(client, [:statuses, signal_group_status_path, :cycle], cycle)

    phases =
      for {sg, sg_plan} <- cur_plan(client), into: %{} do
        {sg, String.at(sg_plan, cycle)}
      end

    phase_string = Map.values(phases) |> Enum.join()
    client = put_in(client, [:statuses, signal_group_status_path, :groups], phase_string)

    Site.publish_status(client, signal_group_status_path)

    data = %{topic: "status", changes: [signal_group_status_path]}
    Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", data)

    client
  end

  # update detector counts
  def detect(client) do
    counts_path = "traffic/201/dl/1"
    now = timestamp()

    client = client |> put_in([:statuses, counts_path, :vehicles], :rand.uniform(3))
    client = client |> put_in([:statuses, counts_path, :starttime], now)

    Site.publish_status(client, counts_path)

    data = %{topic: "status", changes: [counts_path]}
    Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", data)

    client
  end


  # helpers

  def cur_plan_nr(client), do: client.statuses["tlc/14"].plan
  def cur_plan(client), do: client.plans[cur_plan_nr(client)]
  def cur_offset(client), do: client.statuses["tlc/24"][cur_plan_nr(client)]
  def cur_cycletime(client), do: client.statuses["tlc/28"][cur_plan_nr(client)]
end
