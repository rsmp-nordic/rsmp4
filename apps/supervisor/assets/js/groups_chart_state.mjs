// Pure state for GroupsChart — manages a rolling 60-second window of signal group states.
// The server pushes timestamped snapshots; JS draws colored bars.
// Gaps are implicit: time discontinuities between a point's end (next_ts or next point's ts)
// and the following point's start render as grey.

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
  // Each group has an array of {ts, endTs, state} entries (ts in ms since epoch)
  // endTs is the effective end time: next_ts if set, otherwise null (extends to next entry or now)
  const groups = {}
  for (const id of GROUP_IDS) {
    groups[id] = []
  }
  return { groups }
}

// Receive a full history array from the server: [{ts, next_ts, groups: {1: "G", 2: "r", ...}}, ...]
// next_ts may be null (meaning: extends to the next point's ts, or to now if last).
export function receiveHistory(state, history) {
  // Reset
  for (const id of GROUP_IDS) {
    state.groups[id] = []
  }

  for (const point of history) {
    const endTs = point.next_ts || null

    for (const id of GROUP_IDS) {
      if (point.groups && point.groups[id] !== undefined) {
        const entries = state.groups[id]
        const last = entries.length > 0 ? entries[entries.length - 1] : null
        // Only push if state actually changed or first entry
        if (!last || last.state !== point.groups[id] || last.endTs !== null) {
          entries.push({ ts: point.ts, endTs, state: point.groups[id] })
        } else if (endTs !== null) {
          // Same state, deduped — but propagate endTs to the existing entry
          last.endTs = endTs
        }
      }
    }
  }
}
