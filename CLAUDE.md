# RSMP 4 — Copilot Instructions

## Specification

This repo implements the **RSMP 4** specification: https://github.com/rsmp-nordic/rsmp_core_v4

RSMP 4 is a new major version with no backward compatibility with RSMP 3. Do not add compatibility code or layers — implement only the latest RSMP 4 spec.

## Architecture

Elixir **umbrella project** implementing RSMP 4 (Road-Side Message Protocol) over MQTT. Three OTP apps:

| App | Port | Role |
|-----|------|------|
| `apps/rsmp/` | — | Core library: MQTT connection, protocol logic, streams |
| `apps/site/` | 3000 | Phoenix LiveView — acts as a TLC (site/device) |
| `apps/supervisor/` | 4000 | Phoenix LiveView — acts as a supervisor/TMC |

Both `site` and `supervisor` depend on `{:rsmp, in_umbrella: true}`.

Key architecture doc: [apps/rsmp/docs/architecture.md](../apps/rsmp/docs/architecture.md)

## MQTT & Message Format

- **Broker:** MQTT v5 on `127.0.0.1:1883` (run locally, e.g. `docker start emqx`)
- **Payload encoding:** CBOR (via `cbor` library) — not JSON
- **Topic structure:** `{node_id}/{type}/{module}.{code}[/{stream}][/{component_type}/{n}]`
  - e.g. `tlc_af34/status/tlc.groups/live/tc/1`
- **Presence:** retained `"online"` / `"offline"` at `{id}/presence`
- **Commands** use MQTT 5 `Correlation-Data` as command ID; results echo it back
- Supervisor subscribes to `+/presence/#`, `+/status/#`, `+/alarm/#`, `+/result/#`
- Site subscribes to `{id}/command/#`, `{id}/throttle/#`

## Key Modules (rsmp lib)

- `RSMP.Connection` — GenServer managing one `emqtt` process; dispatches incoming messages
- `RSMP.Node` — per-node supervisor tree (Connection + Services + Streams + Remote.Nodes)
- `RSMP.Service` — `use RSMP.Service, name: "..."` macro for local service GenServers
- `RSMP.Stream` — controls publish behaviour per status (delta, periodic, throttle, aggregation)
- `RSMP.Remote.Nodes` — DynamicSupervisor; spawns `RSMP.Remote.Node` trees as sites come online
- `RSMP.Registry` — wraps `Registry` with structured via-tuples: `{id, :service, module, component}`
- `RSMP.Topic` / `RSMP.Path` — parse/build MQTT topic strings and `module.code/component` paths
- `RSMP.Converter` — behaviour for converting between internal structs and RSMP SXL wire format

## Project Conventions

- **Service macro pattern:** `use RSMP.Service, name: "..."` injects GenServer boilerplate. See [apps/rsmp/lib/rsmp/service/tlc.ex](../apps/rsmp/lib/rsmp/service/tlc.ex)
- **Process naming:** All processes use Registry via-tuples (never plain atoms) to support dynamic multi-node setups
- **Dual polymorphism:** `defprotocol RSMP.Service.Protocol` for dispatch + `@behaviour RSMP.Service.Behaviour` for compile-time callbacks
- **PubSub:** `RSMP.PubSub` (Phoenix.PubSub) broadcasts alarm/status changes to LiveViews on topic `site:#{id}`
- **Node IDs:** Site generates random ID at startup: `tlc_<4hex>` (see `RSMP.Site.Application`)
- **Code comments:** Minimal and focused. Describe the current state of the code only — never explain why/how something was changed


## Build & Test

```bash
# Prerequisites
mise install          # installs Elixir + Erlang versions from .tool-versions
docker start emqx     # MQTT broker on port 1883
docker restart emqx   # restart MQTT broker to clearn retained messages

# Run all apps (from root)
mix phx.server

# Run individual apps
cd apps/site && mix phx.server        # port 3000
cd apps/supervisor && mix phx.server  # port 4000

# Tests (MQTT connections disabled in test env)
mix test                         # all apps
mix test apps/rsmp/test/         # rsmp lib only
```

## Config Notes

- `config :rsmp, :emqtt_connect, false` in `config/test.exs` disables real MQTT in tests
- Tests use `MockConnection` (local GenServer) to intercept `publish_message` casts and assert on topics/CBOR payloads
- `RSMP.Registry` must be started in test `setup` blocks if not already running
- Test files: `messaging_test.exs`, `stream_test.exs`, `topic_test.exs`, `path_test.exs`, `supervisor_test.exs`

