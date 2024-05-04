defmodule RSMP.Dispatcher do
  use GenServer
  require Logger

  defstruct [:id]

  def start_link(id) do
    via = RSMP.Registry.via(:helper, id, __MODULE__)
    GenServer.start_link(__MODULE__, id, name: via)
  end

  @impl GenServer
  def init(id) do
    Logger.info("RSMP: starting dispatcher")
    dispatcher = %__MODULE__{id: id}
    {:ok, dispatcher}
  end

  @impl GenServer
  def handle_cast({:dispatch, publish}, dispatcher) do
    topic = RSMP.Topic.from_string(publish.topic)
    data = RSMP.Utility.from_payload(publish[:payload])

    IO.puts topic.type
    case topic.type do
      "state" ->
        handle_state(dispatcher, topic, data)

      type when type in ["command", "reaction"] ->
        dispatch_to_service(topic, data, publish)

      type when type in ["status", "alarm", "result"] ->
        dispatch_to_remote(dispatcher, topic, data, publish)

      _ ->
        Logger.warning("Igoring unknown command type #{RSMP.Topic.to_string(topic)}")
    end

    {:noreply, dispatcher}
  end

  def handle_state(dispatcher, topic, data) do
    unless topic.id == dispatcher.id do
      # note: out id, not topic.id
      via = RSMP.Registry.via(:helper, dispatcher.id, RSMP.Scanner)
      GenServer.cast(via, {:receive_state, topic, data})
    end
  end

  def dispatch_to_service(topic, data, publish) do
    properties = %{
      response_topic: publish[:properties][:"Response-Topic"],
      command_id: publish[:properties][:"Correlation-Data"]
    }

    case RSMP.Registry.lookup(:service, topic.id, topic.path.module, topic.path.component) do
      [{pid, _value}] ->
        case topic.type do
          "command" -> GenServer.call(pid, {:receive_command, topic, data, properties})
          "reaction" -> GenServer.call(pid, {:receive_reaction, topic, data, properties})
        end

      _ ->
        Logger.warning("No service handling #{RSMP.Topic.to_string(topic)}")
    end
  end

  def dispatch_to_remote(dispatcher, topic, data, _publish) do
    case RSMP.Registry.lookup(:remote, dispatcher.id, topic.id) do
      [{pid, _value}] ->
        case topic.type do
          "status" -> GenServer.cast(pid, {:receive_status, topic, data})
        end

      _ ->
        Logger.warning("No remote handling #{RSMP.Topic.to_string(topic)}")
    end
  end
end
