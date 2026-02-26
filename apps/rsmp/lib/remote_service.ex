defprotocol RSMP.Remote.Service.Protocol do
  def name(service)
  def id(service)

  def receive_status(service, path, data, properties)

  def parse_status(service, code, data)

  def receive_alarm(service, path, data, properties)

  def parse_alarm(service, code, data)
end

defmodule RSMP.Remote.Service do

  defmodule Behaviour do
    @type id :: String.t()
    @type data :: Map.t()

    @callback new(id, data) :: __MODULE__
    @callback name() :: String.t()
  end

  # macro
  defmacro __using__(options) do
    # the following code will be injencted into the module using RSMP.Remote.Service
    name = Keyword.get(options, :name)

    quote do
      use GenServer
      require Logger
      @behaviour RSMP.Remote.Service.Behaviour

      def name(), do: unquote(name)

      def start_link({id, remote_id, service, data}) do
        via = RSMP.Registry.via_remote_service(id, remote_id, service)
        GenServer.start_link(__MODULE__, {remote_id, data}, name: via)
      end

      @impl GenServer
      def init({remote_id, data}) do
        {:ok, new(remote_id, data)}
      end

      @impl GenServer
      def handle_cast({:receive_status, topic, data, properties}, service) do
        data = RSMP.Remote.Service.Protocol.parse_status(service, topic.path.code, data)
        service = RSMP.Remote.Service.Protocol.receive_status(service, topic, data, properties)
        {:noreply, service}
      end

      @impl GenServer
      def handle_cast({:receive_alarm, topic, data, properties}, service) do
        data = RSMP.Remote.Service.Protocol.parse_alarm(service, topic.path.code, data)
        service = RSMP.Remote.Service.Protocol.receive_alarm(service, topic, data, properties)
        {:noreply, service}
      end

    end
  end

  # api
  def publish_command(service, code, data) do
    topic = make_topic(service, "command", code)
    RSMP.Connection.publish_message(topic.id, topic, data, %{retain: false, qos: 2}, %{})
  end

  defp make_topic(service, type, code) do
    id = RSMP.Remote.Service.Protocol.id(service)
    RSMP.Topic.new(id, type, code)
  end

end
