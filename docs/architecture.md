# RSMP 4 — Supervisor Tree & Architecture

## Umbrella Structure

RSMP 4 is an Elixir umbrella project with three OTP applications:

| App | Port | Role |
|-----|------|------|
| `rsmp` | — | Core library: MQTT connection, protocol logic, channels, services |
| `site` | 3000 | Phoenix LiveView — acts as a TLC site/device |
| `supervisor` | 4000 | Phoenix LiveView — acts as a supervisor/TMC |

Both `site` and `supervisor` depend on `{:rsmp, in_umbrella: true}`.

The `rsmp` app owns all RSMP protocol processes. The Phoenix apps provide the web UI only — they do **not** start RSMP nodes at boot. Nodes are created on-demand via LiveView interactions.

---

## Full Supervisor Tree

A running system with one site and one supervisor:

```
RSMP (Supervisor, :one_for_one)                    ← rsmp app root
├── Phoenix.PubSub (RSMP.PubSub)                   ← internal pub/sub
├── Registry (RSMP.Registry)                        ← process lookup
├── RSMP.Sites (DynamicSupervisor)                  ← container for site nodes
│   └── RSMP.Node (Supervisor)                      ← site "tlc_abcd"
│       ├── RSMP.Connection (GenServer)             ← owns 1 :emqtt process
│       ├── RSMP.Services (Supervisor)
│       │   ├── RSMP.Service.TLC (GenServer)
│       │   └── RSMP.Service.Traffic (GenServer)
│       ├── RSMP.Channels (DynamicSupervisor)
│       │   ├── RSMP.Channel (tlc.groups/live)
│       │   ├── RSMP.Channel (tlc.plan/default)
│       │   ├── RSMP.Channel (tlc.plans/default)
│       │   ├── RSMP.Channel (traffic.volume/live)
│       │   └── RSMP.Channel (traffic.volume/5s)
│       └── RSMP.Remote.Nodes (DynamicSupervisor)
│           └── (empty — sites don't track remotes)
│
└── RSMP.Supervisors (DynamicSupervisor)            ← container for supervisor nodes
    └── RSMP.Node (Supervisor)                      ← supervisor "a1b2c3d4"
        ├── RSMP.Connection (GenServer)             ← owns 1 :emqtt process
        ├── RSMP.Services (Supervisor)              ← empty (no local services)
        ├── RSMP.Channels (DynamicSupervisor)       ← empty (no channels)
        └── RSMP.Remote.Nodes (DynamicSupervisor)
            └── RSMP.Remote.Node (Supervisor)       ← per discovered site
                ├── RSMP.Remote.Node.State (GenServer)
                ├── RSMP.Managers (DynamicSupervisor)
                │   ├── RSMP.Manager.TLC (GenServer)       ← started on-demand
                │   └── RSMP.Manager.Generic (GenServer)   ← fallback, on-demand
                └── RSMP.Remote.SiteData (GenServer)       ← supervisor-only

RSMP.Site.Supervisor (Supervisor)                   ← site Phoenix app
├── RSMP.Site.Web.Telemetry
├── Finch (RSMP.Site.Finch)
└── RSMP.Site.Web.Endpoint                          ← port 3000

RSMP.Application.Supervisor (Supervisor)            ← supervisor Phoenix app
├── RSMP.Supervisor.Web.Telemetry
├── Finch (RSMP.Supervisor.Finch)
└── RSMP.Supervisor.Web.Endpoint                    ← port 4000
```

---

## RSMP App — Static Children

`RSMP.Application` starts four static children:

| Child | Type | Purpose |
|-------|------|---------|
| `Phoenix.PubSub` | Supervisor | Broadcasts status/alarm/channel changes to LiveViews |
| `Registry` | Registry | Single shared registry for all process lookups via structured tuples |
| `RSMP.Sites` | DynamicSupervisor | Holds site node trees (e.g. `RSMP.Node.TLC`) |
| `RSMP.Supervisors` | DynamicSupervisor | Holds supervisor node trees (e.g. `RSMP.Node.Monitor`) |

---

## Per-Node Tree (RSMP.Node)

Both site and supervisor nodes share the same `RSMP.Node` supervisor structure. The difference lies in what children they populate:

| Child | Site | Supervisor |
|-------|------|------------|
| `RSMP.Connection` | 1 (owns 1 emqtt) | 1 (owns 1 emqtt) |
| `RSMP.Services` | `Service.TLC` + `Service.Traffic` | empty |
| `RSMP.Channels` | 5 channel processes | empty |
| `RSMP.Remote.Nodes` | typically empty | 1 `Remote.Node` per discovered site |

### Node Wrappers

- **`RSMP.Node.TLC`** — child spec wrapper that calls `RSMP.Node.start_link/4` with TLC services, no managers, and channel configurations. Used by `RSMP.Sites`.
- **`RSMP.Node.Monitor`** — child spec wrapper that calls `RSMP.Node.start_link/4` with no services, a manager map (TLC + Traffic codes), and `type: :supervisor`. Used by `RSMP.Supervisors`.

These wrappers are **not processes** — they only produce the child spec for `RSMP.Node`.

---

## Process Registry

All processes are registered via `RSMP.Registry` using structured via-tuples. No plain atom names are used, enabling dynamic multi-node setups.

| Via-tuple | Process |
|-----------|---------|
| `{id, :node}` | Node supervisor |
| `{id, :connection}` | Connection GenServer |
| `{id, :services}` | Services supervisor |
| `{id, :service, name}` | Individual service (e.g. "tlc") |
| `{id, :channels}` | Channels DynamicSupervisor |
| `{id, :channel, code, channel_name}` | Individual channel |
| `{id, :remotes}` | Remote.Nodes DynamicSupervisor |
| `{id, :remote, remote_id}` | Remote.Node supervisor |
| `{id, :remote_state, remote_id}` | Remote.Node.State |
| `{id, :managers, remote_id}` | Managers DynamicSupervisor |
| `{id, :manager, remote_id, name}` | Individual manager |
| `{id, :site_data, remote_id}` | SiteData (supervisor-only) |
| `{id, :code, code}` | Service lookup by status/command code |

---

## emqtt Lifecycle

### One emqtt Process Per Node

Each `RSMP.Connection` GenServer starts **exactly one** `:emqtt` Erlang process. Sites and supervisors do **not** share emqtt instances. If you have 3 sites and 2 supervisors running, there are 5 independent emqtt processes, each with its own:

- MQTT client ID (`clientid: id`)
- Last-Will-and-Testament (`will_topic: "{id}/presence"`, `will_payload: "offline"`)
- Topic subscriptions
- TCP connection to the broker

### Startup

1. `RSMP.Connection.init/1` is called with `{id, managers, options}`.
2. MQTT client options are read from `Application.get_env(:rsmp, :emqtt)` and merged with per-node settings (client ID, will message).
3. `:emqtt.start_link(options)` creates a linked Erlang process — **not yet connected**.
4. `Process.flag(:trap_exit, true)` is set so the Connection can handle emqtt crashes gracefully.
5. `send(self(), :connect)` triggers an async connection attempt.
6. `handle_info(:connect, ...)` calls `:emqtt.connect(emqtt)`:
   - **On success:** subscribes to topics, publishes retained `"online"` presence, triggers services and channels.
   - **On failure:** schedules a retry after 5 seconds via `Process.send_after(self(), :connect, 5_000)`.

### Shutdown

When `RSMP.Connection.terminate/2` is called:

1. **If connected:** publishes `"shutdown"` to `{id}/presence` (retained), clears all retained channel/status messages, then calls `:emqtt.disconnect(emqtt)`.
2. **If not connected but emqtt PID exists:** kills the emqtt process, then opens a temporary short-lived MQTT connection to publish the `"shutdown"` presence message.
3. **If no emqtt PID:** opens a temporary connection to publish `"shutdown"`.

The three-state shutdown logic ensures the presence message is always cleared, even if the MQTT connection was lost before the process terminates.

### Simulated Disconnect/Reconnect

For testing and UI-driven disconnect simulation:

- **`simulate_disconnect/1`:** Kills the emqtt process with `Process.exit(emqtt, :kill)`, sets `connected: false`, broadcasts disconnection via PubSub.
- **`simulate_reconnect/1`:** Starts a new `:emqtt` process via `:emqtt.start_link/1` and triggers `send(self(), :connect)` to initiate a fresh connection.
- **`toggle_connection/1`:** Convenience wrapper that calls disconnect or reconnect based on current state.

### Crash Recovery

Because `trap_exit` is set, if the `:emqtt` process exits unexpectedly:

```elixir
handle_info({:EXIT, pid, _reason}, %{emqtt: pid} = connection)
```

The Connection sets `emqtt: nil` and `connected: false`. The emqtt auto-reconnect behaviour (if configured) or manual reconnect handles recovery.

### emqtt Disconnect Callbacks

`:emqtt` sends `{:disconnected, reason_code}` messages to its owner when the broker drops the connection. The Connection handles these by setting `connected: false` and broadcasting the state change.

---

## Node Startup Lifecycle (On-Demand)

Nodes are **not** started at application boot. They are created on-demand:

1. **Site:** LiveView calls `RSMP.Sites.ensure_site(id)` → `DynamicSupervisor.start_child(RSMP.Sites, {RSMP.Node.TLC, id})`.
2. **Supervisor:** LiveView calls `RSMP.Supervisors.ensure_supervisor(id)` → `DynamicSupervisor.start_child(RSMP.Supervisors, {RSMP.Node.Monitor, id})`.

Inside `RSMP.Node.init/1`:

1. Connection, Services, Channels, and Remote.Nodes supervisors are started as static children.
2. A spawned task starts channels from configuration after a 100ms delay.
3. Services publish initial statuses to seed channel buffers.

---

## Remote Node Discovery (Supervisor Side)

When a supervisor receives a `presence` message from an unknown site:

1. `RSMP.Connection.dispatch_presence/3` checks `RSMP.Registry.lookup_remote/2`.
2. If no existing remote, starts `RSMP.Remote.Node` under `RSMP.Remote.Nodes` DynamicSupervisor.
3. The Remote.Node supervisor starts:
   - `RSMP.Remote.Node.State` — tracks online/offline status
   - `RSMP.Managers` — DynamicSupervisor for on-demand managers
   - `RSMP.Remote.SiteData` — (supervisor-only) stores received statuses, alarms, channels

Managers (`RSMP.Manager.TLC`, `RSMP.Manager.Generic`) are started **lazily** when a status/alarm/result message first arrives for a code that maps to that manager.

---

## Message Dispatch

`RSMP.Connection` dispatches incoming MQTT messages based on topic type:

| Topic Type | Handler | Target |
|------------|---------|--------|
| `presence` | `dispatch_presence` | Creates Remote.Node if new; updates state |
| `command` | `dispatch_to_service` | Routes to local Service by code |
| `throttle` | `dispatch_to_service` | Starts/stops a Channel |
| `fetch` | `dispatch_fetch` | Routes to Channel for historical data |
| `status` | `dispatch_to_manager` | Routes to Manager + SiteData |
| `alarm` | `dispatch_to_manager` | Routes to Manager + SiteData |
| `result` | `dispatch_to_manager` | Routes to Manager + SiteData |
| `channel` | `dispatch_to_manager` | Routes to SiteData |
| `replay` | `dispatch_to_manager` | Routes to SiteData |
| `history` | `dispatch_to_manager` | Routes to SiteData |

---

## MQTT Subscriptions

### Site subscribes to:
```
{id}/command/#
{id}/throttle/#
{id}/fetch/#
```

### Supervisor subscribes to:
```
+/+/+/presence          ← wildcard matching all site IDs (3-level prefix)
+/+/+/status/#
+/+/+/alarm/#
+/+/+/result/#
+/+/+/channel/#
+/+/+/replay/#
{id}/history/#
```

The number of wildcard levels is configurable via `:rsmp, :topic_prefix_levels` (default: 3).
