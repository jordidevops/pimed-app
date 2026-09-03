import { useRef, useEffect, useCallback, useState } from 'react'
import { Eraser, Pen, Check } from 'lucide-react'

// =============================================================================
// Types
// =============================================================================

export interface SignaturePadProps {
  /** Callback quan l'usuari accepta la signatura. Rep base64 PNG. */
  onConfirm: (signatureBase64: string) => void
  /** Callback quan l'usuari cancel·la. */
  onCancel?: () => void
  /** Títol a mostrar sobre el pad. */
  title?: string
  /** Subtítol/instruccions. */
  subtitle?: string
  /** Amplada del canvas (px). Default: 600. */
  width?: number
  /** Alçada del canvas (px). Default: 200. */
  height?: number
  /** Si true, el botó Confirmar apareix desactivat fins que s'ha dibuixat alguna cosa. */
  requireDraw?: boolean
  /** Color de la línia de signatura. Default: '#111827'. */
  strokeColor?: string
  /** Amplada de línia. Default: 2. */
  strokeWidth?: number
  disabled?: boolean
}

// =============================================================================
// SignaturePad
// =============================================================================

export function SignaturePad({
  onConfirm,
  onCancel,
  title = 'Signatura digital',
  subtitle = 'Dibuixa la teva signatura a l\'àrea inferior',
  width  = 600,
  height = 200,
  requireDraw = true,
  strokeColor = '#111827',
  strokeWidth = 2,
  disabled = false,
}: SignaturePadProps) {
  const canvasRef   = useRef<HTMLCanvasElement>(null)
  const isDrawing   = useRef(false)
  const lastPos     = useRef<{ x: number; y: number } | null>(null)
  const [hasDrawn, setHasDrawn] = useState(false)
  const [isEmpty, setIsEmpty]   = useState(true)

  // ─── Inicialitzar canvas ────────────────────────────────────────────────────
  const initCanvas = useCallback(() => {
    const canvas = canvasRef.current
    if (!canvas) return
    const ctx = canvas.getContext('2d')
    if (!ctx) return
    ctx.fillStyle = '#ffffff'
    ctx.fillRect(0, 0, canvas.width, canvas.height)
    ctx.strokeStyle = strokeColor
    ctx.lineWidth   = strokeWidth
    ctx.lineCap     = 'round'
    ctx.lineJoin    = 'round'
  }, [strokeColor, strokeWidth])

  useEffect(() => { initCanvas() }, [initCanvas])

  // ─── Obtenir posició relativa al canvas ─────────────────────────────────────
  const getPos = useCallback((e: MouseEvent | TouchEvent): { x: number; y: number } | null => {
    const canvas = canvasRef.current
    if (!canvas) return null
    const rect = canvas.getBoundingClientRect()
    const scaleX = canvas.width  / rect.width
    const scaleY = canvas.height / rect.height

    if (e instanceof TouchEvent) {
      const touch = e.touches[0] ?? e.changedTouches[0]
      if (!touch) return null
      return {
        x: (touch.clientX - rect.left) * scaleX,
        y: (touch.clientY - rect.top)  * scaleY,
      }
    }

    return {
      x: (e.clientX - rect.left) * scaleX,
      y: (e.clientY - rect.top)  * scaleY,
    }
  }, [])

  // ─── Dibuix ─────────────────────────────────────────────────────────────────
  const startDraw = useCallback((e: MouseEvent | TouchEvent) => {
    if (disabled) return
    e.preventDefault()
    isDrawing.current = true
    const pos = getPos(e)
    lastPos.current = pos
    if (pos) {
      const ctx = canvasRef.current?.getContext('2d')
      if (ctx) {
        ctx.beginPath()
        ctx.arc(pos.x, pos.y, strokeWidth / 2, 0, 2 * Math.PI)
        ctx.fillStyle = strokeColor
        ctx.fill()
      }
    }
  }, [disabled, getPos, strokeColor, strokeWidth])

  const draw = useCallback((e: MouseEvent | TouchEvent) => {
    if (!isDrawing.current || disabled) return
    e.preventDefault()
    const pos = getPos(e)
    if (!pos || !lastPos.current) return

    const canvas = canvasRef.current
    const ctx    = canvas?.getContext('2d')
    if (!ctx) return

    ctx.strokeStyle = strokeColor
    ctx.lineWidth   = strokeWidth
    ctx.lineCap     = 'round'
    ctx.lineJoin    = 'round'
    ctx.beginPath()
    ctx.moveTo(lastPos.current.x, lastPos.current.y)
    ctx.lineTo(pos.x, pos.y)
    ctx.stroke()

    lastPos.current = pos
    if (!hasDrawn) {
      setHasDrawn(true)
      setIsEmpty(false)
    }
  }, [disabled, getPos, hasDrawn, strokeColor, strokeWidth])

  const stopDraw = useCallback(() => {
    isDrawing.current = false
    lastPos.current   = null
  }, [])

  // ─── Event listeners (mouse + touch) ────────────────────────────────────────
  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return

    canvas.addEventListener('mousedown',  startDraw)
    canvas.addEventListener('mousemove',  draw)
    canvas.addEventListener('mouseup',    stopDraw)
    canvas.addEventListener('mouseleave', stopDraw)
    canvas.addEventListener('touchstart', startDraw,  { passive: false })
    canvas.addEventListener('touchmove',  draw,       { passive: false })
    canvas.addEventListener('touchend',   stopDraw)

    return () => {
      canvas.removeEventListener('mousedown',  startDraw)
      canvas.removeEventListener('mousemove',  draw)
      canvas.removeEventListener('mouseup',    stopDraw)
      canvas.removeEventListener('mouseleave', stopDraw)
      canvas.removeEventListener('touchstart', startDraw)
      canvas.removeEventListener('touchmove',  draw)
      canvas.removeEventListener('touchend',   stopDraw)
    }
  }, [startDraw, draw, stopDraw])

  // ─── Esborrar ────────────────────────────────────────────────────────────────
  const handleClear = () => {
    initCanvas()
    setHasDrawn(false)
    setIsEmpty(true)
  }

  // ─── Exportar PNG base64 i confirmar ─────────────────────────────────────────
  const handleConfirm = () => {
    const canvas = canvasRef.current
    if (!canvas) return
    const dataUrl = canvas.toDataURL('image/png')
    onConfirm(dataUrl)
  }

  // ─── Exportar PNG (helper per a tests) ──────────────────────────────────────
  void (canvasRef.current?.toDataURL('image/png') ?? '')

  const canConfirm = !requireDraw || !isEmpty

  return (
    <div className="flex flex-col items-center gap-4 select-none">
      {/* Capçalera */}
      <div className="text-center">
        <h3 className="text-base font-semibold text-gray-900">{title}</h3>
        <p className="text-sm text-gray-500 mt-0.5">{subtitle}</p>
      </div>

      {/* Àrea de dibuix */}
      <div className="relative rounded-lg border-2 border-dashed border-gray-300 bg-white overflow-hidden shadow-inner"
           style={{ width: Math.min(width, 600), touchAction: 'none' }}>
        <canvas
          ref={canvasRef}
          width={width}
          height={height}
          style={{ display: 'block', maxWidth: '100%', cursor: disabled ? 'not-allowed' : 'crosshair' }}
          aria-label="Àrea de signatura"
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

      {/* Controls */}
      <div className="flex items-center gap-3">
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

// Exposar exportAsPng per a tests
export type { SignaturePadProps as SignaturePadPropsType }
