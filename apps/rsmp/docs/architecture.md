# RSMP Library Architecture

The `rsmp` app is a library used by both the `site` (device) and `supervisor` (controller) applications to communicate via the RSMP 4 protocol over MQTT.

## Core Concepts

The library distinguishes between **Local Services** (services running on this node) and **Remote Services** (proxies for services running on a connected node).

### 1. Connection & Routing
- **`RSMP.Connection`**: Manages the MQTT connection (using `emqtt`).
  - Subscribes to relevant topics (`command`, `status`, `alarm`, etc.).
  - Dispatches incoming messages to the appropriate process via `RSMP.Registry`.
- **`RSMP.Registry`**: A custom registry wrapper handling process lookup for connections, nodes, and services.

### 2. Services (Local)
Used when acting as a Device/Site.
- **`RSMP.Service`**: A behaviour and macro for implementing local services.
  - Represents a component on the local device (e.g., a Traffic Light Controller).
  - Handles **incoming commands**.
  - Publishes **statuses** and **alarms**.
- **`RSMP.Service.Protocol`**: Protocol defining how a service handles commands and formats status updates.
- **Example**: `RSMP.Service.TLC` (in `lib/tlc_service.ex`).

### 3. Remote Services (Proxies)
Used when acting as a Supervisor/Controller.
- **`RSMP.Remote.Service`**: A behaviour and macro for tracking remote components.
  - Maintains the state (mirror) of a remote component.
  - Handles **incoming statuses** and **alarms**.
  - Publishes **commands**.
- **`RSMP.Remote.Service.Protocol`**: Protocol defining how a remote service parses and applies status/alarm updates.
- **Example**: `RSMP.Remote.Service.TLC` (in `lib/tlc_manager.ex`).

## Messaging Flows

### Statuses
1.  **Publisher (Local)**: `RSMP.Service` calls `publish_status(service, code)`. This formats the status using `RSMP.Service.Protocol.format_status/2` and publishes it via `RSMP.Connection`.
2.  **Receiver (Remote)**: `RSMP.Connection` receives the MQTT message and dispatches it to the corresponding `RSMP.Remote.Service` process via `receive_status` cast.
3.  **Update**: The remote service parses the payload (`parse_status`) and updates its internal state struct.

### Commands
1.  **Publisher (Remote)**: `RSMP.Remote.Service` calls `publish_command(service, code, data)`. This wraps the data in a command topic and publishes it.
2.  **Receiver (Local)**: `RSMP.Connection` receives the command and calls the local `RSMP.Service` process via `receive_command` (GenServer call).
3.  **Execution**: The local service executes the logic in `receive_command`, returns a result, and typically triggers a state change (often followed by a status publication).
4.  **Result**: The `RSMP.Service` generic implementation automatically publishes a `result` message back to the sender if the command succeeds.

### Alarms
1.  **Publisher (Local)**: A service sets alarm bits and publishes updates (Implementation details in `RSMP.Service` or manual publication).
2.  **Receiver (Remote)**: `RSMP.Connection` receives the alarm message and casts to `receive_alarm` on the `RSMP.Remote.Service`.
3.  **Update**: The remote service creates or updates an `RSMP.Alarm` struct within its state using `parse_alarm` and `receive_alarm`.

## TLC Codes In Use

- **Statuses**
  - `tlc.groups`
  - `tlc.plan`
  - `tlc.plans`
- **Alarms**
  - `tlc.hardware.error`
  - `tlc.hardware.warning`
- **Commands**
  - `tlc.plan.set`

## File Structure

- `lib/connection.ex`: MQTT process and message dispatcher.
- `lib/service.ex`: Behaviour for local services.
- `lib/remote_service.ex`: Behaviour for remote services.
- `lib/tlc_service.ex`: Implementation of the Traffic Light Controller (TLC) local service.
- `lib/tlc_manager.ex`: Implementation of the TLC remote service (Proxy).
- `lib/remote_service_generic.ex`: Fallback implementation for unknown remote services.
- `lib/alarm.ex`: Struct and utilities for managing alarm flags (active, acknowledged, blocked).
- `lib/topic.ex` & `lib/path.ex`: Helpers for parsing and generating RSMP topic strings.
