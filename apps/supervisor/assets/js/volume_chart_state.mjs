// Pure state machine for VolumeChart — no uPlot, no DOM, no timers.
// All stateful mutations happen via the functions exported here.

export const MAX_POINTS = 60

export function createState(maxPoints = MAX_POINTS) {
  return {
    buf: { cars: [], bicycles: [], busses: [] },
    pending: null,
    maxPoints,
  }
}

// Replace the buffer with a batch of pre-computed bins (oldest first).
// Called on mount and on site reconnect with server-stored history.
export function receiveHistory(state, bins) {
  const slice = bins.slice(-state.maxPoints)
  state.buf.cars     = slice.map(b => b.cars     ?? 0)
  state.buf.bicycles = slice.map(b => b.bicycles ?? 0)
  state.buf.busses   = slice.map(b => b.busses   ?? 0)
  state.pending = null
  // History just replaced the buffer with wall-clock-aligned bins.
  // Skip the next tick push so it doesn't immediately shift the buffer
  // by one position and cause a visible left-right jitter.
  state.skipNextTick = true
}

// Called once per second by the interval timer.
// Returns the updated draw data.
export function tickSecond(state) {
  if (state.skipNextTick) {
    // History just replaced the buffer — don't push a new bin this tick
    // or the graph will shift 1 bin left then snap back on the next history.
    state.skipNextTick = false
    return drawData(state)
  }
  if (state.pending) {
    pushBin(state, state.pending)
    state.pending = null
  } else {
    pushBin(state, { cars: 0, bicycles: 0, busses: 0 })
  }
  return drawData(state)
}

// Called when a live volume_point event arrives from the server.
// Queues the bin for the next timer tick so the graph scrolls at a constant rate.
export function receivePoint(state, point) {
  state.pending = point
  return null
}

// Push one bin onto the rolling buffer.
export function pushBin(state, { cars, bicycles, busses }) {
  state.buf.cars.push(cars)
  state.buf.bicycles.push(bicycles)
  state.buf.busses.push(busses)

  if (state.buf.cars.length > state.maxPoints) {
    state.buf.cars.shift()
    state.buf.bicycles.shift()
    state.buf.busses.shift()
  }
}

// Compute the arrays uPlot needs.
export function drawData(state) {
  const n = state.buf.cars.length
  const xs = Array.from({ length: n }, (_, i) => i + (state.maxPoints - n))
  const total      = state.buf.cars.map((c, i) => c + state.buf.bicycles[i] + state.buf.busses[i])
  const carsBicycles = state.buf.cars.map((c, i) => c + state.buf.bicycles[i])
  const carsOnly   = [...state.buf.cars]
  return [xs, total, carsBicycles, carsOnly]
}
