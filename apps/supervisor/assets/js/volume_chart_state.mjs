// Pure state machine for VolumeChart — no uPlot, no DOM, no timers.
// The server pushes a complete bin array every second; JS just renders it.

export const MAX_POINTS = 60

export function createState(maxPoints = MAX_POINTS) {
  return {
    buf: { cars: [], bicycles: [], busses: [] },
    maxPoints,
  }
}

// Replace the buffer with server-computed bins (oldest first).
// Called every second by the server tick and on mount.
export function receiveHistory(state, bins) {
  const slice = bins.slice(-state.maxPoints)
  state.buf.cars     = slice.map(b => b.cars     ?? 0)
  state.buf.bicycles = slice.map(b => b.bicycles ?? 0)
  state.buf.busses   = slice.map(b => b.busses   ?? 0)
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
