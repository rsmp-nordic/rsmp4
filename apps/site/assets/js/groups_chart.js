import { createState, receiveHistory, WINDOW_SECONDS, GROUP_IDS, STATE_COLORS } from "./groups_chart_state.mjs"

const ROW_HEIGHT = 8
const ROW_GAP = 1
const LABEL_WIDTH = 20
const CHART_HEIGHT = GROUP_IDS.length * (ROW_HEIGHT + ROW_GAP) + ROW_GAP

function draw(canvas, state) {
  const ctx = canvas.getContext("2d")
  const dpr = window.devicePixelRatio || 1
  const w = canvas.clientWidth
  const h = CHART_HEIGHT

  canvas.width = w * dpr
  canvas.height = h * dpr
  canvas.style.height = h + "px"
  ctx.scale(dpr, dpr)

  const barLeft = LABEL_WIDTH
  const barWidth = w - LABEL_WIDTH
  const nowMs = Date.now()
  const windowStart = nowMs - WINDOW_SECONDS * 1000

  for (let i = 0; i < GROUP_IDS.length; i++) {
    const groupId = GROUP_IDS[i]
    const entries = state.groups[groupId]
    const y = ROW_GAP + i * (ROW_HEIGHT + ROW_GAP)

    // Label to the left
    ctx.fillStyle = "#374151"
    ctx.font = "11px sans-serif"
    ctx.textBaseline = "middle"
    ctx.textAlign = "right"
    ctx.fillText(groupId, LABEL_WIDTH - 4, y + ROW_HEIGHT / 2)

    if (entries.length === 0) {
      ctx.fillStyle = "#d1d5db"
      ctx.fillRect(barLeft, y, barWidth, ROW_HEIGHT)
      continue
    }

    // Gray fill before first entry
    if (entries[0].ts > windowStart) {
      const endFrac = (entries[0].ts - windowStart) / (WINDOW_SECONDS * 1000)
      ctx.fillStyle = "#d1d5db"
      ctx.fillRect(barLeft, y, barWidth * Math.min(endFrac, 1), ROW_HEIGHT)
    }

    // Colored bars for each state segment
    for (let j = 0; j < entries.length; j++) {
      const entry = entries[j]
      const nextEntry = entries[j + 1]

      const startMs = Math.max(entry.ts, windowStart)
      const endMs = nextEntry ? Math.min(nextEntry.ts, nowMs) : nowMs

      if (endMs <= windowStart || startMs >= nowMs) continue

      const x1 = barLeft + barWidth * ((startMs - windowStart) / (WINDOW_SECONDS * 1000))
      const x2 = barLeft + barWidth * ((endMs - windowStart) / (WINDOW_SECONDS * 1000))

      ctx.fillStyle = entry.state === null ? "#d1d5db" : (STATE_COLORS[entry.state] || "#9ca3af")
      ctx.fillRect(x1, y, Math.max(x2 - x1, 1), ROW_HEIGHT)
    }
  }
}

const GroupsChart = {
  mounted() {
    this.state = createState()

    this.canvas = document.createElement("canvas")
    this.canvas.style.width = "100%"
    this.canvas.style.height = CHART_HEIGHT + "px"
    this.canvas.style.display = "block"
    this.el.appendChild(this.canvas)

    draw(this.canvas, this.state)

    this.handleEvent("groups_history", ({ history }) => {
      receiveHistory(this.state, history)
      draw(this.canvas, this.state)
    })

    const containerEl = this.el.closest(".overflow-x-auto") || this.el.closest("main")
    this._resizeObserver = new ResizeObserver(() => {
      draw(this.canvas, this.state)
    })
    this._resizeObserver.observe(containerEl)
  },

  destroyed() {
    if (this._resizeObserver) this._resizeObserver.disconnect()
  },
}

export default GroupsChart
