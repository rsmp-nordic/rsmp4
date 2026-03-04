# Plan: Modernize Supervisor to Use RSMP Lib Modules

**Scope:** Minimal — reuse `RSMP.Node`/`RSMP.Connection`, keep supervisor-specific logic in a thin per-site GenServer.  
**LiveView API:** Direct Registry lookups (no facade module).

---

## Step 1 — Extend `RSMP.Connection` Supervisor-Mode Subscriptions

`RSMP.Connection` already subscribes to `+/presence/#`, `+/status/#`, `+/alarm/#`, `+/result/#` in supervisor mode. Add the missing subscriptions:

- `+/channel/#`
- `+/replay/#`
- `+/history/#`

In `subscribe_to_topics/1`, add these three patterns to the `:supervisor` branch.

In `handle_publish/5`, add dispatch clauses for `"channel"`, `"replay"`, and `"history"` message types (currently only `"status"`, `"alarm"`, `"result"`, `"presence"` are handled).

---

## Step 2 — Add PubSub Broadcasting for Supervisor Mode

`RSMP.Connection` does not currently broadcast PubSub events for the supervisor. Add broadcasts on:

- `"supervisor:#{id}"` — connection state changes, site online/offline
- `"supervisor:#{id}:#{remote_id}"` — per-site status/alarm/channel updates

This replaces the PubSub broadcasting currently done inline in the `RSMP.Supervisor` monolith.

---

## Step 3 — Create `RSMP.Remote.Service.Site`

New per-remote-site GenServer holding the supervisor-specific state that doesn't belong in `RSMP.Remote.Service.TLC` or `RSMP.Remote.Service.Generic`:

- **Data history** — circular buffer of recent data points per code (currently `data_points` in the monolith's per-site map)
- **Channel state** — tracks which channels are active per code, with seq tracking
- **Gap detection** — detects seq gaps in incoming status messages
- **Volume aggregation** — aggregates `traffic.volume` data points into periodic summaries
- **Status envelope parsing** — extracts `seq`, `ts`, `next_ts`, `values` from incoming CBOR payloads
- **SXL converter dispatch** — calls the appropriate `RSMP.Converter` for the code

Register via `{supervisor_id, :site_data, remote_id}` in `RSMP.Registry`.

---

## Step 4 — Add Gap-Fetch Logic to `RSMP.Remote.Service.Site`

Move the gap-fetch orchestration from the monolith into `RSMP.Remote.Service.Site`:

- `send_fetch/3` — publish a fetch request to the site's `fetch` topic
- Handle incoming `history` responses — merge returned data points into the buffer
- Handle incoming `replay` messages — fill gaps with replayed data
- Auto-fetch on reconnect — when a site comes back online, detect the gap since `last_disconnected_at` and fetch missing data
- Auto-fetch on channel start — when a new channel is started, fetch recent history

Track `pending_fetches` keyed by correlation ID.

---

## Step 5 — Add Command/Throttle Sending to `RSMP.Remote.Service.Site`

Provide public API functions that LiveViews can call:

- `set_plan(supervisor_id, site_id, plan)` — publish a `tlc.plan.set` command
- `start_channel(supervisor_id, site_id, code, channel_name)` — publish a throttle start message
- `stop_channel(supervisor_id, site_id, code, channel_name)` — publish a throttle stop message

These use `RSMP.Connection.publish_message/2` via the supervisor's connection process (looked up in Registry).

---

## Step 6 — Wire `RSMP.Remote.Service.Site` into `RSMP.Remote.Node`

When `RSMP.Remote.Nodes` spawns a `RSMP.Remote.Node` tree for a newly-discovered site, include `RSMP.Remote.Service.Site` as a child (supervisor mode only).

The `RSMP.Remote.Node` supervisor already starts `Remote.Node.State` + remote service processes. Add `RSMP.Remote.Service.Site` alongside the existing remote service children.

---

## Step 7 — Update `RSMP.Node.Monitor` Configuration

`RSMP.Node.Monitor` currently starts `RSMP.Node` with a `managers` map built from module definitions. Extend it to also pass:

- `gap_fetch_channels` config — which channels should trigger automatic gap-fetch on reconnect
- Any supervisor-specific config needed by `RSMP.Remote.Service.Site`

---

## Step 8 — Switch `RSMP.Supervisors` to Start `RSMP.Node.Monitor`

`RSMP.Supervisors` (the DynamicSupervisor) currently starts `RSMP.Supervisor` (the monolith) instances. Change it to start `RSMP.Node.Monitor` instead, which in turn starts the full `RSMP.Node` supervision tree.

This is the point where the monolith is no longer started. Ensure the supervisor app's `Application.start/2` calls `RSMP.Supervisors` with the right config.

---

## Step 9 — Update LiveView Index (`index.ex`)

Replace monolith calls with direct Registry lookups:

| Old (monolith) | New (Registry / direct) |
|---|---|
| `RSMP.Supervisor.connected?(id)` | `RSMP.Connection.connected?(id)` via Registry |
| `RSMP.Supervisor.sites(id)` | `RSMP.Registry.lookup(id, :remote, :_)` to list remote nodes |
| `RSMP.Supervisor.toggle_connection(id)` | `RSMP.Connection.toggle(id)` or similar |
| `RSMP.Connection.get_socket_stats(id)` | Already correct (will now work since Connection exists) |

PubSub subscription stays on `"supervisor:#{id}"`.

---

## Step 10 — Update LiveView Site (`site.ex`)

Replace monolith calls with `RSMP.Remote.Service.Site` lookups:

| Old (monolith) | New (direct) |
|---|---|
| `RSMP.Supervisor.site(id, site_id)` | `RSMP.Remote.Service.Site.get_state(id, site_id)` |
| `RSMP.Supervisor.data_points(id, site_id, code)` | `RSMP.Remote.Service.Site.data_points(id, site_id, code)` |
| `RSMP.Supervisor.data_points_with_keys(id, site_id, code, keys)` | `RSMP.Remote.Service.Site.data_points_with_keys(...)` |
| `RSMP.Supervisor.gap_time_ranges(id, site_id, code)` | `RSMP.Remote.Service.Site.gap_time_ranges(...)` |
| `RSMP.Supervisor.set_plan(id, site_id, plan)` | `RSMP.Remote.Service.Site.set_plan(id, site_id, plan)` |
| `RSMP.Supervisor.start_channel(id, site_id, ...)` | `RSMP.Remote.Service.Site.start_channel(...)` |
| `RSMP.Supervisor.stop_channel(id, site_id, ...)` | `RSMP.Remote.Service.Site.stop_channel(...)` |
| `RSMP.Supervisor.send_fetch(id, site_id, ...)` | `RSMP.Remote.Service.Site.send_fetch(...)` |

PubSub subscription stays on `"supervisor:#{id}:#{site_id}"`.

---

## Step 11 — Delete `RSMP.Supervisor` Monolith

Once all LiveView references are updated and tests pass, delete `apps/rsmp/lib/supervisor.ex` (the 1049-line monolith).

Keep `apps/rsmp/lib/supervisors.ex` (the DynamicSupervisor) — it's still needed, just starting `RSMP.Node.Monitor` instead of the monolith.

---

## Verification

After each step, run:

```bash
mix compile --warnings-as-errors
mix test apps/rsmp/test/
```

After steps 9–10, manually verify the LiveView UI works:

```bash
docker start emqx
mix phx.server
# Open http://localhost:4000 and confirm site list, status updates, commands work
```
