import uPlot from "uplot"
import { createState, receiveHistory, drawData, MAX_POINTS } from "./volume_chart_state.mjs"

function makeBars(size) {
  return uPlot.paths.bars({ size: [size, 100], gap: 0 })
}

function buildChart(el, width) {
  const barPaths = makeBars(0.9)

  return new uPlot(
    {
      width: width,
      height: 130,
      padding: [0, 0, 0, 0],
      legend: { show: false },
      cursor: { show: false },
      select: { show: false },
      scales: {
        x: { time: false, range: (_u, _min, _max) => [0, MAX_POINTS] },
        y: { auto: true },
      },
      axes: [
        { show: false },
        {
          stroke: "#374151",
          ticks: { stroke: "#d1d5db", width: 1 },
          grid: { stroke: "#e5e7eb", width: 1 },
          font: "11px sans-serif",
          labelFont: "11px sans-serif",
          size: 36,
        },
      ],
      hooks: {
        drawClear: [
          (u) => {
            u.ctx.save()
            u.ctx.fillStyle = "#f3f4f6"
            u.ctx.fillRect(0, 0, u.ctx.canvas.width, u.ctx.canvas.height)
            u.ctx.restore()
          },
        ],
      },
      series: [
        {},
        // drawn back-to-front so stacked: total (busses on top), then bicycles, then cars
        {
          label: "Busses",
          fill: "rgba(251,146,60,0.85)",
          stroke: "rgba(251,146,60,0.85)",
          width: 0,
          paths: barPaths,
        },
        {
          label: "Bicycles",
          fill: "rgba(37,99,235,0.85)",
          stroke: "rgba(37,99,235,0.85)",
          width: 0,
          paths: barPaths,
        },
        {
          label: "Cars",
          fill: "rgba(88,28,135,0.85)",
          stroke: "rgba(88,28,135,0.85)",
          width: 0,
          paths: barPaths,
        },
      ],
    },
    [[], [], [], []],
    el
  )
}

const VolumeChart = {
  mounted() {
    this.state = createState()

    const width = this.el.offsetWidth || 600
    this.chart = buildChart(this.el, width)

    // Server pushes a complete bin array every second — just render it.
    this.handleEvent("volume_history", ({ bins }) => {
      receiveHistory(this.state, bins)
      this.chart.setData(drawData(this.state))
    })

    this._resizeObserver = new ResizeObserver(() => {
      const w = this.el.offsetWidth
      if (w > 0) this.chart.setSize({ width: w, height: 130 })
    })
    this._resizeObserver.observe(this.el)
  },

  destroyed() {
    if (this._resizeObserver) this._resizeObserver.disconnect()
    if (this.chart) this.chart.destroy()
  },
}

export default VolumeChart
