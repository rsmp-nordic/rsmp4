import uPlot from "uplot"

const MAX_POINTS = 60

function makeBars(size) {
  return uPlot.paths.bars({ size: [size, 100], gap: 0 })
}

function buildChart(el, width) {
  const barPaths = makeBars(0.9)

  return new uPlot(
    {
      width: width,
      height: 130,
      padding: [8, 0, 0, 0],
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
          stroke: "#9ca3af",
          ticks: { stroke: "#374151", width: 1 },
          grid: { stroke: "#1f2937", width: 1 },
          font: "11px sans-serif",
          labelFont: "11px sans-serif",
          size: 36,
        },
      ],
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
          fill: "rgba(74,222,128,0.85)",
          stroke: "rgba(74,222,128,0.85)",
          width: 0,
          paths: barPaths,
        },
        {
          label: "Cars",
          fill: "rgba(96,165,250,0.85)",
          stroke: "rgba(96,165,250,0.85)",
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
    this.buf = { cars: [], bicycles: [], busses: [] }

    const width = this.el.offsetWidth || 600
    this.chart = buildChart(this.el, width)

    this.handleEvent("volume_point", (point) => {
      const { cars, bicycles, busses } = point
      this.buf.cars.push(cars)
      this.buf.bicycles.push(bicycles)
      this.buf.busses.push(busses)

      // keep only the last MAX_POINTS entries
      if (this.buf.cars.length > MAX_POINTS) {
        this.buf.cars.shift()
        this.buf.bicycles.shift()
        this.buf.busses.shift()
      }

      const n = this.buf.cars.length
      const xs = Array.from({ length: n }, (_, i) => i + (MAX_POINTS - n))

      // stacked cumulative values for back-to-front drawing
      const total = this.buf.cars.map(
        (c, i) => c + this.buf.bicycles[i] + this.buf.busses[i]
      )
      const carsBicycles = this.buf.cars.map((c, i) => c + this.buf.bicycles[i])
      const carsOnly = [...this.buf.cars]

      this.chart.setData([xs, total, carsBicycles, carsOnly])
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
