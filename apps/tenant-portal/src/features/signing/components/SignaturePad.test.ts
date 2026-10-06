import { describe, expect, it } from 'vitest'
import { canvasPosFromPointer } from './SignaturePad'

describe('canvasPosFromPointer', () => {
  it('maps client coordinates onto canvas pixels', () => {
    const canvas = {
      width: 560,
      height: 240,
      getBoundingClientRect: () => ({
        left: 10,
        top: 20,
        width: 280,
        height: 120,
      }),
    } as HTMLCanvasElement

    expect(canvasPosFromPointer(canvas, { clientX: 10, clientY: 20 })).toEqual({ x: 0, y: 0 })
    expect(canvasPosFromPointer(canvas, { clientX: 150, clientY: 80 })).toEqual({ x: 280, y: 120 })
  })
})
