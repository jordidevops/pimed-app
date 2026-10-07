'use client'

import { useRef, useCallback, useState, useEffect } from 'react'

export type SignaturePadProps = {
  onConfirm: (signatureBase64: string) => void
  onCancel?: () => void
  title?: string
  subtitle?: string
  width?: number
  height?: number
  requireDraw?: boolean
  strokeColor?: string
  strokeWidth?: number
  disabled?: boolean
  confirmLabel?: string
  clearLabel?: string
  cancelLabel?: string
  drawHint?: string
}

function canvasPosFromPointer(
  canvas: HTMLCanvasElement,
  e: Pick<PointerEvent, 'clientX' | 'clientY'>,
): { x: number; y: number } {
  const rect = canvas.getBoundingClientRect()
  const scaleX = canvas.width / rect.width
  const scaleY = canvas.height / rect.height
  return {
    x: (e.clientX - rect.left) * scaleX,
    y: (e.clientY - rect.top) * scaleY,
  }
}

export function SignaturePad({
  onConfirm,
  onCancel,
  title = 'Signatura digital',
  subtitle = 'Dibuixa amb el dit, el llapis o el ratolí',
  width = 600,
  height = 220,
  requireDraw = true,
  strokeColor = '#111827',
  strokeWidth = 2.5,
  disabled = false,
  confirmLabel = 'Confirmar signatura',
  clearLabel = 'Esborrar',
  cancelLabel = 'Cancel·lar',
  drawHint = 'Dibuixa aquí la teva signatura',
}: SignaturePadProps) {
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const isDrawing = useRef(false)
  const lastPos = useRef<{ x: number; y: number } | null>(null)
  const [isEmpty, setIsEmpty] = useState(true)

  useEffect(() => {
    const canvas = canvasRef.current
    const ctx = canvas?.getContext('2d')
    if (!canvas || !ctx) return
    ctx.fillStyle = '#ffffff'
    ctx.fillRect(0, 0, canvas.width, canvas.height)
  }, [width, height])

  const paintDot = useCallback(
    (pos: { x: number; y: number }) => {
      const ctx = canvasRef.current?.getContext('2d')
      if (!ctx) return
      ctx.fillStyle = strokeColor
      ctx.beginPath()
      ctx.arc(pos.x, pos.y, strokeWidth / 2, 0, 2 * Math.PI)
      ctx.fill()
    },
    [strokeColor, strokeWidth],
  )

  const paintStroke = useCallback(
    (from: { x: number; y: number }, to: { x: number; y: number }) => {
      const ctx = canvasRef.current?.getContext('2d')
      if (!ctx) return
      ctx.strokeStyle = strokeColor
      ctx.lineWidth = strokeWidth
      ctx.lineCap = 'round'
      ctx.lineJoin = 'round'
      ctx.beginPath()
      ctx.moveTo(from.x, from.y)
      ctx.lineTo(to.x, to.y)
      ctx.stroke()
    },
    [strokeColor, strokeWidth],
  )

  const startDraw = useCallback(
    (e: React.PointerEvent<HTMLCanvasElement>) => {
      if (disabled) return
      e.preventDefault()
      e.currentTarget.setPointerCapture(e.pointerId)
      isDrawing.current = true
      const canvas = canvasRef.current
      if (!canvas) return
      const pos = canvasPosFromPointer(canvas, e)
      lastPos.current = pos
      paintDot(pos)
      setIsEmpty(false)
    },
    [disabled, paintDot],
  )

  const draw = useCallback(
    (e: React.PointerEvent<HTMLCanvasElement>) => {
      if (!isDrawing.current || disabled) return
      e.preventDefault()
      const canvas = canvasRef.current
      if (!canvas || !lastPos.current) return
      const pos = canvasPosFromPointer(canvas, e)
      paintStroke(lastPos.current, pos)
      lastPos.current = pos
    },
    [disabled, paintStroke],
  )

  const stopDraw = useCallback((e: React.PointerEvent<HTMLCanvasElement>) => {
    if (e.currentTarget.hasPointerCapture(e.pointerId)) {
      e.currentTarget.releasePointerCapture(e.pointerId)
    }
    isDrawing.current = false
    lastPos.current = null
  }, [])

  const handleClear = () => {
    const canvas = canvasRef.current
    const ctx = canvas?.getContext('2d')
    if (!canvas || !ctx) return
    ctx.fillStyle = '#ffffff'
    ctx.fillRect(0, 0, canvas.width, canvas.height)
    setIsEmpty(true)
  }

  const handleConfirm = () => {
    const canvas = canvasRef.current
    if (!canvas) return
    onConfirm(canvas.toDataURL('image/png'))
  }

  const canConfirm = !requireDraw || !isEmpty

  return (
    <div className="flex w-full flex-col items-center gap-4 select-none">
      <div className="text-center">
        <h3 className="text-base font-semibold">{title}</h3>
        <p className="sans mt-0.5 text-sm text-[var(--muted)]">{subtitle}</p>
      </div>

      <div
        className="relative w-full max-w-[600px] overflow-hidden rounded-lg border border-dashed border-[var(--line)] bg-white"
        style={{ touchAction: 'none' }}
      >
        <canvas
          ref={canvasRef}
          width={width}
          height={height}
          className="block w-full"
          style={{
            touchAction: 'none',
            cursor: disabled ? 'not-allowed' : 'crosshair',
            height: `${Math.min(height, 280)}px`,
          }}
          aria-label={drawHint}
          onPointerDown={startDraw}
          onPointerMove={draw}
          onPointerUp={stopDraw}
          onPointerCancel={stopDraw}
        />
        {isEmpty && !disabled && (
          <div className="pointer-events-none absolute inset-0 flex items-center justify-center">
            <span className="sans text-sm text-gray-300">{drawHint}</span>
          </div>
        )}
      </div>

      <div className="flex flex-wrap items-center justify-center gap-3">
        <button
          type="button"
          onClick={handleClear}
          disabled={disabled || isEmpty}
          className="sans px-3 py-2 text-sm text-[var(--muted)] underline-offset-2 hover:underline disabled:opacity-40"
        >
          {clearLabel}
        </button>
        {onCancel && (
          <button
            type="button"
            onClick={onCancel}
            disabled={disabled}
            className="sans px-3 py-2 text-sm text-[var(--muted)] underline-offset-2 hover:underline disabled:opacity-40"
          >
            {cancelLabel}
          </button>
        )}
        <button
          type="button"
          onClick={handleConfirm}
          disabled={disabled || !canConfirm}
          className="sans rounded bg-[var(--accent)] px-4 py-2 text-sm text-white disabled:opacity-40"
        >
          {confirmLabel}
        </button>
      </div>
    </div>
  )
}
