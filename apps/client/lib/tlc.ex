defmodule RSMP.Client.TLC do
  use RSMP.Client

  def client_id do
    "tlc_#{SecureRandom.hex(4)}"
  end

  def init_client(client) do
    client
    |> Map.merge(%{
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

  def continue() do
    Process.send_after(self(), :tick, 1000)
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

    publish_status(client, signal_group_status_path)

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

    publish_status(client, counts_path)

    data = %{topic: "status", changes: [counts_path]}
    Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", data)

    client
  end

  # set current time plan
  defp handle_publish(
         ["command", "tlc", "2"],
         component,
         %{payload: payload, properties: properties},
         client
       ) do
    options = %{
      component: component,
      plan: from_payload(payload),
      response_topic: properties[:"Response-Topic"],
      command_id: properties[:"Correlation-Data"]
    }

    {:noreply, set_plan(client, options)}
  end

  def set_plan(client, %{
        component: _component,
        plan: plan,
        response_topic: response_topic,
        command_id: command_id
      }) do
    current_plan = client.statuses["tlc/14"]["status"]
    status_path = "tlc/14"

    {response, client} =
      cond do
        plan == current_plan ->
          Logger.info("RSMP: Already using plan: #{plan}")

          {
            %{status: "already", plan: plan, reason: "Already using plan #{plan}"},
            client
          }

        client.plans[plan] != nil ->
          Logger.info("RSMP: Switching to plan: #{plan}")

          client =
            client |> put_in([:statuses, status_path], %{"status" => plan, "source" => "forced"})

          {
            %{status: "ok", plan: plan, reason: ""},
            client
          }

        true ->
          Logger.info("RSMP: Unknown plan: #{plan}")

          {
            %{status: "unknown", plan: plan, reason: "Plan #{plan} not found"},
            client
          }
      end

    if response_topic do
      properties = %{
        "Correlation-Data": command_id
      }

      # Client, Topic, Properties, Payload, Opts, Timeout, Callback
      :emqtt.publish_async(
        client.pid,
        response_topic,
        properties,
        to_payload(response),
        [retain: true, qos: 1],
        :infinity,
        &publish_done/1
      )
    end

    if response[:status] == "ok" do
      publish_status(client, status_path)

      data = %{topic: "status", changes: [status_path]}
      Phoenix.PubSub.broadcast(RSMP.PubSub, "rsmp", data)
    end

    client
  end

  # import status from sxl format to internal format

  def parse_rsmp_status("tlc/1", _component, data) do
    %{
      base: data["basecyclecounter"],
      cycle: data["cyclecounter"],
      groups: data["signalgroupstatus"],
      stage: data["stage"]
    }
  end

  def parse_rsmp_status("tlc/14", _component, data) do
    %{
      plan: data["status"],
      source: data["source"]
    }
  end

  def parse_rsmp_status("tlc/24", _component, data) do
    items = String.split(data["status"], ",")

    for item <- items, into: %{} do
      [plan, value] = String.split(item, "-")
      {String.to_integer(plan), String.to_integer(value)}
    end
  end

  def parse_rsmp_status("tlc/28", component, data),
    do: parse_rsmp_status("tlc/24", component, data)

  # export status from internal format to sxl format

  def format_rsmp_status("tlc/1", _component, data) do
    %{
      "basecyclecounter" => data.base,
      "cyclecounter" => data.cycle,
      "signalgroupstatus" => data.groups,
      "stage" => data.stage
    }
  end

  def format_rsmp_status("tlc/14", _component, data) do
    %{
      "status" => data.plan,
      "source" => data.source
    }
  end

  def format_rsmp_status("tlc/22", _component, data) do
    items =
      data
      |> Enum.join(",")

    %{"status" => items}
  end

  def format_rsmp_status("tlc/24", _component, data) do
    items =
      data
      |> Enum.map(fn {plan, value} -> "#{plan}-#{value}" end)
      |> Enum.join(",")

    %{"status" => items}
  end

  def format_rsmp_status("tlc/28", component, data),
    do: format_rsmp_status("tlc/24", component, data)

  def format_rsmp_status("traffic/201", ["dl", _dl], data) do
    %{
      "starttime" => data.starttime,
      "vehicles" => data.vehicles
    }
  end

  # helpers

  def cur_plan_nr(client), do: client.statuses["tlc/14"].plan
  def cur_plan(client), do: client.plans[cur_plan_nr(client)]
  def cur_offset(client), do: client.statuses["tlc/24"][cur_plan_nr(client)]
  def cur_cycletime(client), do: client.statuses["tlc/28"][cur_plan_nr(client)]
end
