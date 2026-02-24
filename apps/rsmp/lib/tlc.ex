defmodule RSMP.Node.TLC do
  alias RSMP.Channel.Config

  def make_site_id(), do: SecureRandom.hex(4)

  @doc """
  Channel configurations demonstrating various channel patterns:

  1. groups/live - Live signal group status with Send on Change/Send Along.
     cyclecounter is Send Along so it doesn't trigger updates alone.
     Default off (high-frequency, start when needed).

  2. plan (no channel name) - Current plan, single channel.
     Default on (low-frequency, always useful).

  3. plans (no channel name) - Available plans, single channel.
     Default on (rarely changes).
  """
  def channel_configs do
    [
      {"tlc", %Config{
        code: "groups",
        channel_name: "live",
        attributes: %{
          "signalgroupstatus" => :on_change,
          "stage" => :on_change,
          "cyclecounter" => :send_along
        },
        update_rate: 60_000,
        delta_rate: :on_change,
        min_interval: 100,
        default_on: false,
        qos: 0,
        replay_rate: 2,
        history_rate: 2
      }},
      {"tlc", %Config{
        code: "plan",
        channel_name: nil,
        attributes: %{
          "status" => :on_change,
          "source" => :send_along
        },
        update_rate: 300_000,
        delta_rate: :on_change,
        min_interval: 0,
        default_on: true,
        qos: 1
      }},
      {"tlc", %Config{
        code: "plans",
        channel_name: nil,
        attributes: %{
          "status" => :on_change
        },
        update_rate: 300_000,
        delta_rate: :on_change,
        min_interval: 0,
        default_on: true,
        qos: 1
      }},
      {"traffic", %Config{
        code: "volume",
        channel_name: "live",
        attributes: %{
          "cars" => :on_change,
          "bicycles" => :on_change,
          "busses" => :on_change
        },
        update_rate: nil,
        delta_rate: :on_change,
        min_interval: 0,
        default_on: true,
        qos: 0,
        replay_rate: 4,
        history_rate: 4,
        always_publish: true
      }},
      {"traffic", %Config{
        code: "volume",
        channel_name: "5s",
        attributes: %{
          "cars" => :on_change,
          "bicycles" => :on_change,
          "busses" => :on_change
        },
        update_rate: 5_000,
        align_full_updates: true,
        delta_rate: :off,
        aggregation: :sum,
        min_interval: 0,
        default_on: true,
        qos: 1
      }}
    ]
  end

  def child_spec(id) do
    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [id]},
      type: :supervisor
    }
  end

  def start_link(id, options \\ []) do
    services = [
      {[], RSMP.Service.TLC, %{plan: 1, groups: initial_groups()}},
      {[], RSMP.Service.Traffic, %{}}
    ]
    managers = %{
    }

    options = options ++ [channels: channel_configs()]

    RSMP.Node.start_link(id, services, managers, options)
  end

  @doc "Initial signal group states for a simulated 4-group intersection"
  def initial_groups do
    %{
      "1" => "G",
      "2" => "r",
      "3" => "G",
      "4" => "r"
    }
  end

  def get_statuses(site_id) do
    tlc_statuses =
      case RSMP.Registry.lookup_service(site_id, "tlc", []) do
        [{service_pid, _}] ->
          statuses = RSMP.Service.get_statuses(service_pid)

          for {code, data} <- statuses, into: %{} do
            data = RSMP.Converter.TLC.from_rsmp_status(code, data)
            {"tlc." <> code, data}
          end

        [] ->
          %{}
      end

    traffic_statuses =
      case RSMP.Registry.lookup_service(site_id, "traffic", []) do
        [{service_pid, _}] ->
          statuses = RSMP.Service.get_statuses(service_pid)

          for {code, data} <- statuses, into: %{} do
            {"traffic." <> code, data}
          end

        [] ->
          %{}
      end

    Map.merge(tlc_statuses, traffic_statuses)
  end

  def get_alarms(site_id) do
    case RSMP.Registry.lookup_service(site_id, "tlc", []) do
      [{service_pid, _}] ->
        alarms = RSMP.Service.get_alarms(service_pid)
        for {code, alarm} <- alarms, into: %{} do
          {"tlc." <> code, alarm}
        end
      [] -> %{}
    end
  end

  def get_channels(site_id) do
    RSMP.Channels.list_channel_info(site_id)
  end

  def start_channel(site_id, module, code, channel_name) do
    case RSMP.Registry.lookup_channel(site_id, module, code, channel_name, []) do
      [{pid, _}] -> RSMP.Channel.start_channel(pid)
      [] -> {:error, :not_found}
    end
  end

  def stop_channel(site_id, module, code, channel_name) do
    case RSMP.Registry.lookup_channel(site_id, module, code, channel_name, []) do
      [{pid, _}] -> RSMP.Channel.stop_channel(pid)
      [] -> {:error, :not_found}
    end
  end

  def get_traffic_level(site_id) do
    case RSMP.Registry.lookup_service(site_id, "traffic", []) do
      [{service_pid, _}] -> GenServer.call(service_pid, :get_traffic_level)
      [] -> :low
    end
  end

  def set_traffic_level(site_id, level) when level in [:none, :sparse, :low, :high] do
    case RSMP.Registry.lookup_service(site_id, "traffic", []) do
      [{service_pid, _}] ->
        GenServer.cast(service_pid, {:set_traffic_level, level})
        :ok

      [] ->
        :error
    end
  end

  def set_traffic_level(_site_id, _level), do: :error

  def set_alarm(site_id, path, flags) do
    code = String.replace_prefix(path, "tlc.", "")
    case RSMP.Registry.lookup_service(site_id, "tlc", []) do
      [{service_pid, _}] ->
        RSMP.Service.set_alarm(service_pid, code, flags)
      [] -> :ok
    end
  end

  def set_plan(site_id, plan) do
    case RSMP.Registry.lookup_service(site_id, "tlc", []) do
      [{service_pid, _}] ->
        path = RSMP.Path.new("tlc", "plan.set")
        topic = %RSMP.Topic{path: path}
        data = %{"plan" => plan}
        GenServer.call(service_pid, {:receive_command, topic, data, %{}})
      [] -> :error
    end
  end

  def set_plan_local(site_id, plan) do
    case RSMP.Registry.lookup_service(site_id, "tlc", []) do
      [{service_pid, _}] -> GenServer.call(service_pid, {:set_plan_local, plan})
      [] -> :error
    end
  end

  def get_volume_data_points(site_id) do
    case RSMP.Registry.lookup_service(site_id, "traffic", []) do
      [{service_pid, _}] -> GenServer.call(service_pid, :get_data_points)
      [] -> []
    end
  end

  def get_groups_history(site_id) do
    case RSMP.Registry.lookup_service(site_id, "tlc", []) do
      [{service_pid, _}] -> GenServer.call(service_pid, :get_groups_history)
      [] -> []
    end
  end

end
