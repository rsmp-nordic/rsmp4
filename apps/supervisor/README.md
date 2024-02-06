# RSMP 4 Supervisor
This is part of an experiment to see how RSMP 4 could be build on top of MQTT.

This Phoenix web app acts as an RSMP supervisor.

## Running
The MQTT broker and the MQTT device (rsmp_mqtt) should be running (or you can start them afterwards)-

To start your Phoenix server:

  * Run `mix setup` to install and setup dependencies
  * Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.


# CLI
From iex (Interactive Elixir) you can use the RSMP.Supervisor module to interact with RSMP MQTT clients. If you have a client running, you should see commands send to the client:

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

