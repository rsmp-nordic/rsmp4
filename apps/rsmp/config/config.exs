# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]


# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

config :rsmp, :emqtt,
  host: ~c"127.0.0.1",
  port: 1883,
  proto_ver: :v5,
  clean_start: false,
  name: :emqtt,
  reconnect: :infinity

config :rsmp, :sensor_id, "tlc_582a"

config :logger, level: :debug
