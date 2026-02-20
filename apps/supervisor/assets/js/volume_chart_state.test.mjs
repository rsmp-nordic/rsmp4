import { test, describe } from "node:test"
import assert from "node:assert/strict"
import {
  createState,
  tickSecond,
  receivePoint,
  receiveHistory,
  pushBin,
  drawData,
  MAX_POINTS,
} from "./volume_chart_state.mjs"

// ---------------------------------------------------------------------------
// receiveHistory
// ---------------------------------------------------------------------------

describe("receiveHistory", () => {
  test("populates buffer from server batch", () => {
    const s = createState()
    const bins = [
      { cars: 1, bicycles: 2, busses: 0 },
      { cars: 3, bicycles: 0, busses: 1 },
    ]
    receiveHistory(s, bins)
    assert.equal(s.buf.cars.length, 2)
    assert.deepEqual(s.buf.cars, [1, 3])
    assert.deepEqual(s.buf.bicycles, [2, 0])
    assert.deepEqual(s.buf.busses, [0, 1])
  })

  test("slices to maxPoints when batch exceeds capacity", () => {
    const s = createState(3)
    const bins = [
      { cars: 1, bicycles: 0, busses: 0 },
      { cars: 2, bicycles: 0, busses: 0 },
      { cars: 3, bicycles: 0, busses: 0 },
      { cars: 4, bicycles: 0, busses: 0 },
      { cars: 5, bicycles: 0, busses: 0 },
    ]
    receiveHistory(s, bins)
    assert.equal(s.buf.cars.length, 3)
    assert.deepEqual(s.buf.cars, [3, 4, 5]) // oldest dropped
  })

  test("empty batch leaves buffer empty", () => {
    const s = createState()
    receiveHistory(s, [])
    assert.equal(s.buf.cars.length, 0)
  })

  test("clears any pending point", () => {
    const s = createState()
    s.pending = { cars: 9, bicycles: 0, busses: 0 }
    receiveHistory(s, [{ cars: 1, bicycles: 0, busses: 0 }])
    assert.equal(s.pending, null)
  })

  test("defaults missing fields to 0", () => {
    const s = createState()
    receiveHistory(s, [{ cars: 5 }])
    assert.equal(s.buf.cars[0], 5)
    assert.equal(s.buf.bicycles[0], 0)
    assert.equal(s.buf.busses[0], 0)
  })

  test("history followed by live ticks appends correctly", () => {
    const s = createState(5)
    receiveHistory(s, [
      { cars: 1, bicycles: 0, busses: 0 },
      { cars: 2, bicycles: 0, busses: 0 },
    ])
    s.pending = { cars: 3, bicycles: 0, busses: 0 }
    tickSecond(s)
    assert.equal(s.buf.cars.length, 3)
    assert.equal(s.buf.cars[2], 3)
  })
})

// ---------------------------------------------------------------------------
// tickSecond
// ---------------------------------------------------------------------------

describe("tickSecond", () => {
  test("consumes pending point and pushes it to buffer", () => {
    const s = createState()
    s.pending = { cars: 4, bicycles: 1, busses: 2 }
    tickSecond(s)
    assert.equal(s.buf.cars.length, 1)
    assert.equal(s.buf.cars[0], 4)
    assert.equal(s.pending, null)
  })

  test("no pending → zero bin added (site offline)", () => {
    const s = createState()
    tickSecond(s)
    assert.equal(s.buf.cars[0], 0)
    assert.equal(s.buf.bicycles[0], 0)
    assert.equal(s.buf.busses[0], 0)
  })

  test("buffer never grows beyond maxPoints", () => {
    const s = createState(5)
    for (let i = 0; i < 10; i++) tickSecond(s)
    assert.equal(s.buf.cars.length, 5)
  })

  test("returns drawData array", () => {
    const s = createState(3)
    const result = tickSecond(s)
    assert.ok(Array.isArray(result))
    assert.equal(result.length, 4) // [xs, total, carsBicycles, carsOnly]
  })
})

// ---------------------------------------------------------------------------
// receivePoint
// ---------------------------------------------------------------------------

describe("receivePoint", () => {
  test("stores point as pending", () => {
    const s = createState()
    receivePoint(s, { cars: 7, bicycles: 1, busses: 0 })
    assert.deepEqual(s.pending, { cars: 7, bicycles: 1, busses: 0 })
  })

  test("pending is consumed on next tick", () => {
    const s = createState()
    receivePoint(s, { cars: 7, bicycles: 1, busses: 0 })
    tickSecond(s)
    assert.equal(s.buf.cars[s.buf.cars.length - 1], 7)
    assert.equal(s.pending, null)
  })

  test("second point overwrites first before tick", () => {
    const s = createState()
    receivePoint(s, { cars: 1, bicycles: 0, busses: 0 })
    receivePoint(s, { cars: 99, bicycles: 0, busses: 0 })
    assert.equal(s.pending.cars, 99)
  })

  test("returns null", () => {
    const s = createState()
    const result = receivePoint(s, { cars: 1, bicycles: 0, busses: 0 })
    assert.equal(result, null)
  })
})

// ---------------------------------------------------------------------------
// pushBin
// ---------------------------------------------------------------------------

describe("pushBin", () => {
  test("appends bin to buffer", () => {
    const s = createState()
    pushBin(s, { cars: 3, bicycles: 2, busses: 1 })
    assert.equal(s.buf.cars.length, 1)
    assert.equal(s.buf.cars[0], 3)
    assert.equal(s.buf.bicycles[0], 2)
    assert.equal(s.buf.busses[0], 1)
  })

  test("oldest bin shifts out when buffer at capacity", () => {
    const s = createState(3)
    pushBin(s, { cars: 1, bicycles: 0, busses: 0 })
    pushBin(s, { cars: 2, bicycles: 0, busses: 0 })
    pushBin(s, { cars: 3, bicycles: 0, busses: 0 })
    pushBin(s, { cars: 4, bicycles: 0, busses: 0 })
    assert.equal(s.buf.cars.length, 3)
    assert.deepEqual(s.buf.cars, [2, 3, 4])
  })
})

// ---------------------------------------------------------------------------
// drawData
// ---------------------------------------------------------------------------

describe("drawData", () => {
  test("xs aligns to the right of the maxPoints window", () => {
    const s = createState(10)
    tickSecond(s)
    tickSecond(s)
    tickSecond(s)
    const [xs] = drawData(s)
    assert.deepEqual(xs, [7, 8, 9])
  })

  test("once buffer is full xs starts at 0", () => {
    const s = createState(3)
    tickSecond(s)
    tickSecond(s)
    tickSecond(s)
    const [xs] = drawData(s)
    assert.deepEqual(xs, [0, 1, 2])
  })

  test("stacked series are cumulative (total ≥ carsBicycles ≥ carsOnly)", () => {
    const s = createState()
    s.pending = { cars: 2, bicycles: 3, busses: 1 }
    tickSecond(s)
    const [, total, carsBicycles, carsOnly] = drawData(s)
    assert.deepEqual(total, [6])
    assert.deepEqual(carsBicycles, [5])
    assert.deepEqual(carsOnly, [2])
  })

  test("empty buffer returns empty arrays", () => {
    const s = createState()
    const [xs, total, carsBicycles, carsOnly] = drawData(s)
    assert.deepEqual(xs, [])
    assert.deepEqual(total, [])
    assert.deepEqual(carsBicycles, [])
    assert.deepEqual(carsOnly, [])
  })
})

// ---------------------------------------------------------------------------
// Integration: history + offline + reconnect
// ---------------------------------------------------------------------------

describe("integration: history + offline + reconnect", () => {
  test("on reconnect, receiveHistory replaces offline zeros with real data", () => {
    const s = createState(10)
    // First, site is live for 3 seconds
    s.pending = { cars: 5, bicycles: 0, busses: 0 }
    tickSecond(s)
    s.pending = { cars: 6, bicycles: 0, busses: 0 }
    tickSecond(s)
    s.pending = { cars: 7, bicycles: 0, busses: 0 }
    tickSecond(s)
    assert.deepEqual(s.buf.cars, [5, 6, 7])

    // Site goes offline — 3 zero ticks
    tickSecond(s)
    tickSecond(s)
    tickSecond(s)
    assert.deepEqual(s.buf.cars, [5, 6, 7, 0, 0, 0])

    // Reconnect: server pushes history covering all 6 seconds
    receiveHistory(s, [
      { cars: 5, bicycles: 0, busses: 0 },
      { cars: 6, bicycles: 0, busses: 0 },
      { cars: 7, bicycles: 0, busses: 0 },
      { cars: 1, bicycles: 0, busses: 0 },
      { cars: 2, bicycles: 0, busses: 0 },
      { cars: 3, bicycles: 0, busses: 0 },
    ])
    assert.deepEqual(s.buf.cars, [5, 6, 7, 1, 2, 3])
  })

  test("receiveHistory caps at maxPoints when server sends more", () => {
    const s = createState(5)
    const bins = Array.from({ length: 20 }, (_, i) => ({ cars: i + 1, bicycles: 0, busses: 0 }))
    receiveHistory(s, bins)
    assert.equal(s.buf.cars.length, 5)
    assert.deepEqual(s.buf.cars, [16, 17, 18, 19, 20])
  })
})
