// Pure state for GroupsChart — manages a rolling 60-second window of signal group states.
// The server pushes timestamped snapshots; JS draws colored bars.

export const WINDOW_SECONDS = 60
export const GROUP_IDS = ["1", "2", "3", "4"]

// State color mapping: code → CSS color
export const STATE_COLORS = {
  G: "#22c55e",  // green-500
  Y: "#eab308",  // yellow-500
  r: "#ef4444",  // red-500
  u: "#f59e0b",  // amber-500 (red+yellow)
}

export function createState() {
  // Each group has an array of {ts, state} entries (ts in ms since epoch)
  const groups = {}
  for (const id of GROUP_IDS) {
    groups[id] = []
  }
  return { groups }
}

// Receive a full history array from the server: [{ts, groups: {1: "G", 2: "r", ...}}, ...]
export function receiveHistory(state, history) {
  // Reset
  for (const id of GROUP_IDS) {
    state.groups[id] = []
  }

  for (const point of history) {
    // Gap marker: insert null-state entry for all groups
    if (point.gap) {
      for (const id of GROUP_IDS) {
        state.groups[id].push({ ts: point.ts, state: null })
      }
      continue
    }

    for (const id of GROUP_IDS) {
      if (point.groups && point.groups[id] !== undefined) {
        const entries = state.groups[id]
        const last = entries.length > 0 ? entries[entries.length - 1] : null
        // Only push if state actually changed or first entry
        if (!last || last.state !== point.groups[id]) {
          entries.push({ ts: point.ts, state: point.groups[id] })
        }
      }
    }
  }
}
