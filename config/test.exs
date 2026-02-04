# Test environment configuration
import Config

# Disable Swoosh API client in test environment (no external HTTP adapters needed)
config :swoosh, :api_client, false

config :site, RSMP.Site.Web.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "g2CxU92k0dAXUukLWGyznWkH8doFRSrqBbvfRzEKOGIHNxisoDEmJsx2EvzDsEH1",
  server: false,
  live_view: [signing_salt: "J9xJ9xJ9xJ9xJ9xJ9xJ9xJ9xJ9xJ9x99"],
  render_errors: [
    formats: [html: RSMP.Site.Web.ErrorHTML, json: RSMP.Site.Web.ErrorJSON],
    layout: false
  ]

config :supervisor, RSMP.Supervisor.Web.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4003],
  secret_key_base: "g2CxU92k0dAXUukLWGyznWkH8doFRSrqBbvfRzEKOGIHNxisoDEmJsx2EvzDsEH2",
  server: false,
  live_view: [signing_salt: "K8yK8yK8yK8yK8yK8yK8yK8yK8yK8y88"],
  render_errors: [
    formats: [html: RSMP.Supervisor.Web.ErrorHTML, json: RSMP.Supervisor.Web.ErrorJSON],
    layout: false
  ]

config :rsmp, :emqtt_connect, false
