defprotocol RSMP.Service.Protocol do
  def name(service)
  def id(service)

  def receive_command(service, path, data, properties)

  def format_status(service, code)
end

defmodule RSMP.Service do

  defmodule Behaviour do
    @type id :: String.t()
    @type data :: Map.t()

    @callback new(id, data) :: __MODULE__
    @callback name() :: String.t()
    @callback status_codes() :: [String.t()]
    @callback alarm_codes() :: [String.t()]
  end

  # macro
  defmacro __using__(options) do
    # the following code will be injencted into the module using RSMP.Service
    name = Keyword.get(options, :name)

    quote do
      use GenServer
      require Logger
      @behaviour RSMP.Service.Behaviour

      def name(), do: unquote(name)

      def start_link({id, component, service, data}) do
        via = RSMP.Registry.via_service(id, service, component)
        GenServer.start_link(__MODULE__, {id, data}, name: via)
      end

      @impl GenServer
      def init({id, data}) do
        {:ok, new(id, data)}
      end

      @impl GenServer
      def handle_call(:get_state, _from, service) do
        {:reply, service, service}
      end

      @impl GenServer
      def handle_cast(:publish_all, service) do
        for code <- status_codes() do
          RSMP.Service.report_to_streams(service, code)
        end
        for code <- alarm_codes() do
          RSMP.Service.publish_alarm(service, code)
        end
        {:noreply, service}
      end

      @impl GenServer
      def handle_call({:get_alarms}, _from, service) do
        {:reply, service.alarms, service}
      end

      @impl GenServer
      def handle_cast({:set_alarm, code, flags}, service) do
        alarm = service.alarms[code]
        alarm = RSMP.Alarm.update_from_string_map(alarm, flags)
        alarms = Map.put(service.alarms, code, alarm)
        service = %{service | alarms: alarms}
        RSMP.Service.publish_alarm(service, code)
        Phoenix.PubSub.broadcast(RSMP.PubSub, "site:#{service.id}", %{topic: "alarm"})
        {:noreply, service}
      end

      @impl GenServer
      def handle_call({:get_statuses}, _from, service) do
        statuses =
          for code <- status_codes(), into: %{} do
             {code, RSMP.Service.Protocol.format_status(service, code)}
          end
        {:reply, statuses, service}
      end

      @impl GenServer
      def handle_call({:receive_command, topic, data, properties}, _from, service) do
        {service,result} = RSMP.Service.Protocol.receive_command(service, topic, data, properties)
        if result do
          RSMP.Service.publish_result(service, topic.path.code, topic.path.component, result, properties)
        end
        {:reply, result, service}
      end
    end
  end

  # api
  def get_alarms(pid) do
    GenServer.call(pid, {:get_alarms})
  end

  def set_alarm(pid, code, flags) do
    GenServer.cast(pid, {:set_alarm, code, flags})
  end

  def publish_status(service, code) do
    publish_status(service, code, [])
  end

  def get_statuses(pid) do
    GenServer.call(pid, {:get_statuses})
  end

  def publish_status(service, code, component, properties \\ %{}) do
    topic = make_topic(service, "status", code, component)
    data = RSMP.Service.Protocol.format_status(service, code)
    RSMP.Connection.publish_message(topic.id, topic, data, %{retain: true, qos: 1}, properties)
  end

  def publish_alarm(service, code, component \\ [], properties \\ %{}) do
    topic = make_topic(service, "alarm", code, component)
    alarm = service.alarms[code]

    data = %{
      "aSp" => "Issue",
      "aSt" => if(alarm.active, do: "Active", else: "Inactive"),
      "aTs" => RSMP.Time.timestamp()
    }
    RSMP.Connection.publish_message(topic.id, topic, data, %{retain: true, qos: 1}, properties)
  end

  def publish_result(service, code, component, data, properties \\ %{}) do
    topic = make_topic(service, "result", code, component)
    RSMP.Connection.publish_message(topic.id, topic, data, %{retain: true, qos: 2}, properties)
  end

  @doc """
  Report attribute values to all streams for the given status code.
  Streams will decide whether to publish based on their configuration.
  """
  def report_to_streams(service, code) do
    id = RSMP.Service.Protocol.id(service)
    module = RSMP.Service.Protocol.name(service)
    values = RSMP.Service.Protocol.format_status(service, code)
    report_to_streams(id, module, code, values)
  end

  def report_to_streams(id, module, code, values, ts \\ nil) do
    # Find all streams for this code (any stream_name, any component)
    match_pattern = {{{id, :stream, module, code, :_, :_}, :"$1", :_}, [], [:"$1"]}
    pids = Registry.select(RSMP.Registry, [match_pattern])

    Enum.each(pids, fn pid ->
      RSMP.Stream.report(pid, values, ts)
    end)
  end

  defp make_topic(service, type, code, component) do
    id = RSMP.Service.Protocol.id(service)
    module = RSMP.Service.Protocol.name(service)
    RSMP.Topic.new(id, type, module, code, component)
  end

  #  def alarm_flag_string(service, path) do
  #    service.alarms(path)
  #    |> Map.from_struct()
  #    |> Enum.filter(fn {_flag, value} -> value == true end)
  #    |> Enum.map(fn {flag, _value} -> flag end)
  #    |> inspect()
  #  end
end
