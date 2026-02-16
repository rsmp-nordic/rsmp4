defmodule RSMP.MessagingTest do
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
    # Ensure RSMP.Registry is running.
    # We check if it is already running to avoid crash in RSMP.Registry.start_link (which matches {:ok, _})
    if Process.whereis(RSMP.Registry) == nil do
      RSMP.Registry.start_link()
    end
    :ok
  end

  test "receive status updates service state" do
    # Setup
    id = "site_status_test"
    remote_id = "tlc_remote_1"

    # Start the remote service (TLC)
    # The arguments map to start_link({id, remote_id, service, component, data})
    {:ok, pid} = RSMP.Remote.Service.TLC.start_link({id, remote_id, "tlc", [], %{}})

    # Create the status message
    # Expecting path 'plan' (Status) as defined in RSMP.Remote.Service.TLC.receive_status/4
    topic = RSMP.Topic.new(remote_id, "status", "tlc", "plan")
    data = %{"status" => 2, "source" => "local"}

    # Send receive_status cast
    GenServer.cast(pid, {:receive_status, topic, data, %{}})

    # Assert state is updated
    # We use :sys.get_state to verify internal state of the GenServer
    # Allow some time for cast to process
    :timer.sleep(10)
    state = :sys.get_state(pid)

    assert state.plan == 2
    assert state.source == "local"
  end

  test "send command publishes message to connection" do
    remote_id = "tlc_remote_2"

    # Start MockConnection acting as the connection for remote_id
    start_supervised!({MockConnection, {remote_id, self()}})

    # Create a service struct instance (we don't need the GenServer running for this helper)
    # Pass empty map to avoid BadMapError due to default arg [] in new/2
    service = RSMP.Remote.Service.TLC.new(remote_id, %{})

    # Send command
    RSMP.Remote.Service.publish_command(service, "M0001", %{"arg" => "test"})

    # Assert the message was published
    assert_receive {:published, topic, data}
    assert topic.id == remote_id
    assert topic.type == "command"
    assert topic.path.code == "M0001"
    assert data == %{"arg" => "test"}
  end

  test "receive alarm updates service state" do
    id = "site_alarm_test"
    remote_id = "tlc_remote_3"

    {:ok, pid} = RSMP.Remote.Service.TLC.start_link({id, remote_id, "tlc", [], %{}})

    topic = RSMP.Topic.new(remote_id, "alarm", "tlc", "A0001", ["C1"])
    data = %{"cId" => "C1", "active" => true, "acknowledged" => false}

    GenServer.cast(pid, {:receive_alarm, topic, data, %{}})
    :timer.sleep(10)

    state = :sys.get_state(pid)
    assert state.alarms[{"C1", "A0001"}]
    assert state.alarms[{"C1", "A0001"}].active == true
  end

  test "receive command on local service executes command and updates state" do
    id = "site_local_1"

    # Start MockConnection to capture status update and command result
    start_supervised!({MockConnection, {id, self()}})

    # Start Local TLC Service
    # We pre-populate plans so switching to plan 2 works
    initial_data = %{plans: %{2 => %{desc: "Plan 2"}}}
    {:ok, pid} = RSMP.Service.TLC.start_link({id, [], "tlc", initial_data})

    topic = RSMP.Topic.new(id, "command", "tlc", "plan.set")
    data = %{"plan" => 2}

    # Helper to clean mailbox before call
    # Process can have messages from start_link init if any

    # Send receive_command (Call)
    result = GenServer.call(pid, {:receive_command, topic, data, %{}})

    # Assert Call Result
    assert result == %{status: "ok", plan: 2}

    # Verify State Change
    state = :sys.get_state(pid)
    assert state.plan == 2

    # Status is now delivered via streams only, so no raw status is published.
    # The report_to_streams call will find no streams in this test (none started).

    # Verify Published Result (from generic handle_call)
    assert_receive {:published, topic_result, _data_result}
    assert topic_result.type == "result"
    assert topic_result.path.code == "plan.set"
  end
end
