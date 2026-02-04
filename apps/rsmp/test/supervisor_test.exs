defmodule RSMP.SupervisorTest do
  use ExUnit.Case

  test "handles EXIT messages without crashing" do
    # Ensure RSMP.Supervisor is running
    # In test env, it is started by application
    pid = Process.whereis(RSMP.Supervisor)
    assert pid != nil

    # Prepare an EXIT message
    # We use a fake pid
    fake_pid = spawn(fn -> :ok end)
    exit_msg = {:EXIT, fake_pid, {:shutdown, :econnrefused}}

    # Send the message
    send(pid, exit_msg)

    # Allow some time for processing
    :timer.sleep(10)

    # Verify existing process is still alive (didn't crash)
    assert Process.alive?(pid)
  end
end
