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

  test "keeps previous groups stage when delta omits stage" do
    pid = Process.whereis(RSMP.Supervisor)
    assert pid != nil

    site_id = "supervisor_delta_stage_#{System.unique_integer([:positive])}"

    full_payload =
      RSMP.Utility.to_payload(%{
        "type" => "full",
        "data" => %{
          "signalgroupstatus" => "GrGr",
          "stage" => 2,
          "cyclecounter" => 10
        }
      })

    send(pid, {:publish, %{topic: "#{site_id}/status/tlc.groups/live", payload: full_payload, properties: %{}}})
    :timer.sleep(20)

    delta_payload =
      RSMP.Utility.to_payload(%{
        "type" => "delta",
        "data" => %{
          "signalgroupstatus" => "YrYr",
          "cyclecounter" => 11
        }
      })

    send(pid, {:publish, %{topic: "#{site_id}/status/tlc.groups/live", payload: delta_payload, properties: %{}}})
    :timer.sleep(20)

    status = RSMP.Supervisor.site(site_id).statuses["tlc.groups"]
    assert status.groups == %{"1" => "Y", "2" => "r", "3" => "Y", "4" => "r"}
    assert status.cycle == 11
    assert status.stage == 2
  end

  test "traffic.volume live delta replaces provided counters, not accumulates in supervisor" do
    pid = Process.whereis(RSMP.Supervisor)
    assert pid != nil

    site_id = "supervisor_traffic_delta_#{System.unique_integer([:positive])}"

    full_payload =
      RSMP.Utility.to_payload(%{
        "type" => "full",
        "data" => %{
          "cars" => 4
        }
      })

    send(pid, {:publish, %{topic: "#{site_id}/status/traffic.volume/live", payload: full_payload, properties: %{}}})
    :timer.sleep(20)

    delta_payload =
      RSMP.Utility.to_payload(%{
        "type" => "delta",
        "data" => %{
          "cars" => 6
        }
      })

    send(pid, {:publish, %{topic: "#{site_id}/status/traffic.volume/live", payload: delta_payload, properties: %{}}})
    :timer.sleep(20)

    status = RSMP.Supervisor.site(site_id).statuses["traffic.volume"]
    assert status.cars == 6

    delta_payload_2 =
      RSMP.Utility.to_payload(%{
        "type" => "delta",
        "data" => %{
          "bicycles" => 2
        }
      })

    send(pid, {:publish, %{topic: "#{site_id}/status/traffic.volume/live", payload: delta_payload_2, properties: %{}}})
    :timer.sleep(20)

    status = RSMP.Supervisor.site(site_id).statuses["traffic.volume"]
    assert status.cars == 6
    assert status.bicycles == 2
  end

  test "traffic.volume keeps seq per stream" do
    pid = Process.whereis(RSMP.Supervisor)
    assert pid != nil

    site_id = "supervisor_traffic_seq_map_#{System.unique_integer([:positive])}"

    live_full_payload =
      RSMP.Utility.to_payload(%{
        "type" => "full",
        "seq" => 64,
        "data" => %{
          "cars" => 4
        }
      })

    send(pid, {:publish, %{topic: "#{site_id}/status/traffic.volume/live", payload: live_full_payload, properties: %{}}})
    :timer.sleep(20)

    s5_full_payload =
      RSMP.Utility.to_payload(%{
        "type" => "full",
        "seq" => 12,
        "data" => %{
          "cars" => 4,
          "bicycles" => 1
        }
      })

    send(pid, {:publish, %{topic: "#{site_id}/status/traffic.volume/5s", payload: s5_full_payload, properties: %{}}})
    :timer.sleep(20)

    status = RSMP.Supervisor.site(site_id).statuses["traffic.volume"]
    assert status["seq"] == %{"live" => 64, "5s" => 12}
  end
end
