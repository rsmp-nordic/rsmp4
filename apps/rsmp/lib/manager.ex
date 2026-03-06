defprotocol RSMP.Manager.Protocol do
  def name(manager)
  def id(manager)

  def receive_status(manager, path, data, properties)

  def parse_status(manager, code, data)

  def receive_alarm(manager, path, data, properties)

  def parse_alarm(manager, code, data)
end

defmodule RSMP.Manager do

  defmodule Behaviour do
    @type id :: String.t()
    @type data :: Map.t()

    @callback new(id, data) :: __MODULE__
    @callback name() :: String.t()
  end

  # macro
  defmacro __using__(options) do
    name = Keyword.get(options, :name)

    quote do
      use GenServer
      require Logger
      @behaviour RSMP.Manager.Behaviour

      def name(), do: unquote(name)

      def start_link({id, remote_id, service, data}) do
        via = RSMP.Registry.via_manager(id, remote_id, service)
        GenServer.start_link(__MODULE__, {remote_id, data}, name: via)
      end

      @impl GenServer
      def init({remote_id, data}) do
        {:ok, new(remote_id, data)}
      end

      @impl GenServer
      def handle_cast({:receive_status, topic, data, properties}, manager) do
        data = RSMP.Manager.Protocol.parse_status(manager, topic.path.code, data)
        manager = RSMP.Manager.Protocol.receive_status(manager, topic, data, properties)
        {:noreply, manager}
      end

      @impl GenServer
      def handle_cast({:receive_alarm, topic, data, properties}, manager) do
        data = RSMP.Manager.Protocol.parse_alarm(manager, topic.path.code, data)
        manager = RSMP.Manager.Protocol.receive_alarm(manager, topic, data, properties)
        {:noreply, manager}
      end

      @impl GenServer
      def handle_cast({:receive_result, _topic, _data, _properties}, manager) do
        {:noreply, manager}
      end

    end
  end

  # api
  def publish_command(manager, code, data) do
    topic = make_topic(manager, "command", code)
    RSMP.Connection.publish_message(topic.id, topic, data, %{retain: false, qos: 2}, %{})
  end

  defp make_topic(manager, type, code) do
    id = RSMP.Manager.Protocol.id(manager)
    RSMP.Topic.new(id, type, code)
  end

end
