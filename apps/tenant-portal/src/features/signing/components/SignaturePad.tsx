import { useRef, useCallback, useState, useEffect } from 'react'
import { Eraser, Pen, Check } from 'lucide-react'

export interface SignaturePadProps {
  /** Callback quan l'usuari accepta la signatura. Rep base64 PNG. */
  onConfirm: (signatureBase64: string) => void
  /** Callback quan l'usuari cancel·la. */
  onCancel?: () => void
  /** Títol a mostrar sobre el pad. */
  title?: string
  /** Subtítol/instruccions. */
  subtitle?: string
  /** Amplada lògica del canvas (px). Default: 600. */
  width?: number
  /** Alçada lògica del canvas (px). Default: 220. */
  height?: number
  /** Si true, el botó Confirmar apareix desactivat fins que s'ha dibuixat alguna cosa. */
  requireDraw?: boolean
  /** Color de la línia de signatura. Default: '#111827'. */
  strokeColor?: string
  /** Amplada de línia. Default: 2.5. */
  strokeWidth?: number
  disabled?: boolean
}

function clientPos(
  canvas: HTMLCanvasElement,
  clientX: number,
  clientY: number,
): { x: number; y: number } {
  const rect = canvas.getBoundingClientRect()
  const scaleX = canvas.width / rect.width
  const scaleY = canvas.height / rect.height
  return {
    x: (clientX - rect.left) * scaleX,
    y: (clientY - rect.top) * scaleY,
  }
}

export function canvasPosFromPointer(
  canvas: HTMLCanvasElement,
  e: Pick<PointerEvent, 'clientX' | 'clientY'>,
): { x: number; y: number } {
  return clientPos(canvas, e.clientX, e.clientY)
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
        <h3 className="text-base font-semibold text-gray-900">{title}</h3>
        <p className="text-sm text-gray-500 mt-0.5">{subtitle}</p>
      </div>

      <div
        className="relative w-full max-w-[600px] rounded-lg border-2 border-dashed border-gray-300 bg-white overflow-hidden shadow-inner"
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
          aria-label="Àrea de signatura"
          onPointerDown={startDraw}
          onPointerMove={draw}
          onPointerUp={stopDraw}
          onPointerCancel={stopDraw}
        />
        {isEmpty && !disabled && (
          <div className="absolute inset-0 flex items-center justify-center pointer-events-none">
            <div className="flex items-center gap-2 text-gray-300">
              <Pen className="w-5 h-5" />
              <span className="text-sm font-medium">Dibuixa aquí la teva signatura</span>
            </div>
          </div>
        )}
      </div>

      <div className="flex flex-wrap items-center justify-center gap-3">
        <button
          type="button"
          onClick={handleClear}
          disabled={disabled || isEmpty}
          className="inline-flex items-center gap-1.5 px-3 py-2 text-sm font-medium text-gray-700
                     bg-white border border-gray-300 rounded-lg hover:bg-gray-50
                     disabled:opacity-40 disabled:cursor-not-allowed transition-colors"
        >
          <Eraser className="w-4 h-4" />
          Esborrar
        </button>

        {onCancel && (
          <button
            type="button"
            onClick={onCancel}
            disabled={disabled}
            className="px-4 py-2 text-sm font-medium text-gray-600
                       bg-white border border-gray-300 rounded-lg hover:bg-gray-50
                       disabled:opacity-40 transition-colors"
          >
            Cancel·lar
          </button>
        )}

        <button
          type="button"
          onClick={handleConfirm}
          disabled={disabled || !canConfirm}
          className="inline-flex items-center gap-1.5 px-4 py-2 text-sm font-semibold
                     text-white bg-indigo-600 rounded-lg hover:bg-indigo-700
                     disabled:opacity-40 disabled:cursor-not-allowed transition-colors"
        >
          <Check className="w-4 h-4" />
          Confirmar signatura
        </button>
      </div>
    </div>
  )
}

export type { SignaturePadProps as SignaturePadPropsType }
