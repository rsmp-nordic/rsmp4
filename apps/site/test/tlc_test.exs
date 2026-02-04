defmodule RSMP.Site.TLCTest do
  use ExUnit.Case

  setup do
    # Ensure RSMP.Registry is running
    if Process.whereis(RSMP.Registry) == nil do
      RSMP.Registry.start_link()
    end
    :ok
  end

  test "TLC service handles plan switch command" do
    site_id = "site_integration_test_1"

    # Start the TLC node
    {:ok, _pid} = RSMP.Node.TLC.start_link(site_id)

    # Wait for service to be registered
    Process.sleep(10)

    # Find the service PID
    # We use empty component list [] as configured in RSMP.Node.TLC
    [{service_pid, _}] = RSMP.Registry.lookup_service(site_id, "tlc", [])

    # Construct a valid command topic and payload
    topic = RSMP.Topic.new(site_id, "command", "tlc", "2")
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
         {:ok, _pid} = RSMP.Node.TLC.start_link(site_id)
         [{service_pid, _}] = RSMP.Registry.lookup_service(site_id, "tlc", [])
         topic = RSMP.Topic.new(site_id, "command", "tlc", "2")
         payload = 2 # Invalid payload (integer instead of map)

         # The service logs a warning and returns {service, nil} -> response is nil
         result = GenServer.call(service_pid, {:receive_command, topic, payload, %{}})
         assert result == nil
  end
end
