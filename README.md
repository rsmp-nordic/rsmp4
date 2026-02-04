# RSMP 4

## About
Investigation into how RSMP 4 could be based on MQTT.

The repo is an Elixir umbrella project, containing three apps:

- apps/rsmp: an RSMP library.
- site: a Phoenix web app running on port 3000 that acts as a TLC site.
- supervisor: a Phoenix web app running on port 4000 that acts as a supervisor system.

See apps/rsmp/docs/architecture.md for explanations on the modules that handle RSMP 4 communication.

## Dependencies
You need Elixir And Erlang installed. The recommended way is to install via `mise`.
Once `mise` is installed, you can run `mise install` to install the correct versions of the tools, specified in the file `.tool-versions`.

## MQTT broker
You need an MQTT broker running on port 1883. An easy way to do this is to run emqx with Docker:

`% docker start emqx`

No configuration of the broker is needed.

## Running the site/supervisor web apps
To run a specific app, first cd into the app folder, then use the ELixir `mix` command to run the app.
See the README files in each app folder for more details

If you run `mix` commands in the root folder, they apply to all apps. For example you can run tests for all apps at the same time. See Elixir documentation for more info.

## Inspecting MQTT Traffic
In addition to the log output, you can use a tool like the MQTTX desktop app to see the MQTT messages exchanged via the broker.
