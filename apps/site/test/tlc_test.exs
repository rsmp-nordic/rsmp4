defmodule RSMP.Site.TLCTest do
  use ExUnit.Case

  # MockConnection to intercept messages published via RSMP.Connection
  defmodule MockConnection do
    use GenServer

    def start_link({id, test_pid}) do
      via = RSMP.Registry.via_connection(id)
      GenServer.start_link(__MODULE__, test_pid, name: via)
    end

    def init(test_pid) do
      {:ok, test_pid}
    end

    # Handle the cast from RSMP.Connection.publish_message
    def handle_cast({:publish_message, topic, data, _options, _properties}, test_pid) do
      send(test_pid, {:published, topic, data})
      {:noreply, test_pid}
    end
  end

  setup do
    # Ensure RSMP.Registry is running
    if Process.whereis(RSMP.Registry) == nil do
      RSMP.Registry.start_link()
    end
    :ok
  end

  test "TLC service handles plan switch command" do
    site_id = "site_integration_test_1"

    # Start MockConnection acting as the connection
    start_supervised!({MockConnection, {site_id, self()}})

    # Start the TLC node, but skip the real connection (since we provided a mock)
    {:ok, _pid} = RSMP.Node.TLC.start_link(site_id, connection_module: nil)

    # Wait for service to be registered
    Process.sleep(10)

    # Find the service PID
    # We use empty component list [] as configured in RSMP.Node.TLC
    [{service_pid, _}] = RSMP.Registry.lookup_service(site_id, "tlc")

    # Construct a valid command topic and payload
    topic = RSMP.Topic.new(site_id, "command", "tlc.plan.set")
    payload = %{"plan" => 2}

    # Send the command via GenServer call
    result = GenServer.call(service_pid, {:receive_command, topic, payload, %{}})

    assert result == %{status: "ok", plan: 2}

    # Verify state update
    state = :sys.get_state(service_pid)
    assert state.plan == 2
  end

  test "TLC service rejects invalid payload" do
         site_id = "site_integration_test_bad"

         # Start MockConnection acting as the connection
         start_supervised!({MockConnection, {site_id, self()}})

         {:ok, _pid} = RSMP.Node.TLC.start_link(site_id, connection_module: nil)
         [{service_pid, _}] = RSMP.Registry.lookup_service(site_id, "tlc")
         topic = RSMP.Topic.new(site_id, "command", "tlc.plan.set")
         payload = 2 # Invalid payload (integer instead of map)

         # The service logs a warning and returns {service, nil} -> response is nil
         result = GenServer.call(service_pid, {:receive_command, topic, payload, %{}})
         assert result == nil
  end
end
