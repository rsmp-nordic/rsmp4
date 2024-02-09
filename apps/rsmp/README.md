# RSMP 4
Libary that implements RSMP 4 based on MQTT.


## CLI
From iex (Interactive Elixir) you can use the RSMP.Supervisor module to interact with RSMP MQTT clients and supervisor.

### Supervisor

If you have a client running, you should see commands send to the client:

```sh
%> iex -S mix
Erlang/OTP 25 [erts-13.2.2.3] [source] [64-bit] [smp:8:8] [ds:8:8:10] [async-threads:1]

Interactive Elixir (1.15.5) - press Ctrl+C to exit (type h() ENTER for help)
[info] RSMP: tlc_2b3c3cf7: Received status ./env/humidity: 49 from tlc_2b3c3cf7
[info] RSMP: tlc_2b3c3cf7: Received status ./env/temperature: 28 from tlc_2b3c3cf7
[info] RSMP: tlc_2b3c3cf7: Received status ./tlc/plan: 4 from tlc_2b3c3cf7

iex(4)> RSMP.Supervisor.client_ids()
["tlc_2b3c3cf7", "tlc_7a88044b", "tlc_d8815f19", "tlc_debf8805"]

iex(6)> RSMP.Supervisor.client("tlc_2b3c3cf7")
%{
  alarms: %{
    "env/humidity" => %{
      "acknowledged" => false,
      "active" => false,
      "blocked" => false
    },
    "env/temperature" => %{
      "acknowledged" => false,
      "active" => false,
      "blocked" => false
    }
  },
  num_alarms: 0,
  online: true,
  statuses: %{
    "env/humidity" => 44,
    "env/temperature" => 28
    "tlc/plan" => 1,
  }
}

iex(6)> RSMP.Supervisor.set_plan("tlc_7a88044b",2)
:ok
[info] RSMP: Sending 'plan' command d16a to tlc_7a88044b: Please switch to plan 5
iex(7)> [info] RSMP: tlc_7a88044b: Received response to 'plan' command d16a: %{"plan" => 5, "reason" => "", "status" => "ok"}
[info] RSMP: tlc_7a88044b: Received status ./tlc/plan: 5 from tlc_7a88044b
 ```

### Client
From iex (Interactive Elixir) you can use the RSMP.Client module to interact with RSMP MQTT clients. If you have a supervisor, you should see the client appear online, send status messages, etc:

```sh
%> iex -S mix
Erlang/OTP 25 [erts-13.2.2.3] [source] [64-bit] [smp:8:8] [ds:8:8:10] [async-threads:1]

Interactive Elixir (1.15.5) - press Ctrl+C to exit (type h() ENTER for help)

iex(1)> {:ok,pid} = RSMP.Client.start_link()   # start our client, will send state, statuses and alarms
[info] RSMP: Starting client with pid #PID<0.342.0>
{:ok, #PID<0.342.0>}

iex(4)> pid |> RSMP.Client.get_id()  # show our RSMP/MQTT id
"tlc_b2926093"

iex(5)> pid |> RSMP.Client.get_statuses()  # show our local statuses
%{
  "./env/humidity" => 48,
  "./tlc/plan" => 1,
  "./env/temperature" => 28
}

iex(6)> pid |> RSMP.Client.get_alarms()  # show our local alarms
%{
  "./env/humidity" => %{
    "acknowledged" => false,
    "active" => false,
    "blocked" => false
  },
  "./env/temperature" => %{
    "acknowledged" => false,
    "active" => false,
    "blocked" => false
  }
}

iex(7)> pid |> RSMP.Client.set_status("./env/humidity",49)  # will publish our status, if changed
:ok

iex(9)> pid |> RSMP.Client.raise_alarm("./env/temperature") # will publish alarm, if chahnged
:ok

iex(11)> pid |> RSMP.Client.clear_alarm("./env/temperature") # will publish alarm, if changed
:ok
```
