import Config

# For development, we disable any cache and enable
# debugging and code reloading.
#
# The watchers configuration can be used to run external
# watchers to your application. For example, we can use it
# to bundle .js and .css sources.
config :client, RSMP.Client.Web.Endpoint,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: RSMP.Client.Web.ErrorHTML, json: RSMP.Client.Web.ErrorJSON],
    layout: false
  ],
  pubsub_server: RSMP.PubSub,
  live_view: [signing_salt: "+BqAJ3a1"],
  # Binding to loopback ipv4 address prevents access from other machines.
  # Change to `ip: {0, 0, 0, 0}` to allow access from other machines.
  http: [ip: {127, 0, 0, 1}, port: 3000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "g2CxU92k0dAXUukLWGyznWkH8doFRSrqBbvfRzEKOGIHNxisoDEmJsx2EvzDsEH1",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:client, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:client, ~w(--watch)]}
  ],
  # Watch static and templates for browser reloading.
  live_reload: [
    patterns: [
      ~r"priv/static/.*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/rsmp_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ],
  # Enable dev routes for dashboard and mailbox
  dev_routes: true

config :supervisor, RSMP.Supervisor.Web.Endpoint,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: RSMP.Supervisor.Web.ErrorHTML, json: RSMP.Supervisor.Web.ErrorJSON],
    layout: false
  ],
  pubsub_server: RSMP.PubSub,
  live_view: [signing_salt: "+BqAJ3a2"],
  # Binding to loopback ipv4 address prevents access from other machines.
  # Change to `ip: {0, 0, 0, 0}` to allow access from other machines.
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "g2CxU92k0dAXUukLWGyznWkH8doFRSrqBbvfRzEKOGIHNxisoDEmJsx2EvzDsEH2",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:supervisor, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:supervisor, ~w(--watch)]}
  ],
  # Watch static and templates for browser reloading.
  live_reload: [
    patterns: [
      ~r"priv/static/.*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/rsmp_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ],
  # Enable dev routes for dashboard and mailbox
  dev_routes: true

# Do not include metadata nor timestamps in development logs
config :logger, :console, format: "[$level] $message\n"

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

# Disable swoosh api client as it is only required for production adapters.
config :swoosh, :api_client, false

# config :logger, level: :info
