import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Minus, Plus, Maximize2 } from 'lucide-react'
import { renderAsync } from 'docx-preview'
import PizZip from 'pizzip'
import Docxtemplater from 'docxtemplater'
import { supabase } from '@/lib/supabase'
import { dottedPathParser } from '../utils/docxTemplateIo'
import { Button } from '@/components/ui/button'
import {
  Dialog, DialogContent, DialogHeader, DialogTitle,
} from '@/components/ui/dialog'
import { cn } from '@/lib/utils'

// ─── Pane: inline DOCX preview (no dialog) ───────────────────────────────────

const DOCX_ZOOM_MIN = 0.4
const DOCX_ZOOM_MAX = 1.5
const DOCX_ZOOM_STEP = 0.1

interface DocxPreviewPaneProps {
  storagePath?: string | null
  bucket?: string
  /** Fitxer local (p.ex. acabat de seleccionar, no desat yet). Prioritari sobre storagePath. */
  fileBlob?: Blob | null
  /** Valors per substituir tags DOCX en viu (si existeixen). */
  previewValues?: Record<string, unknown> | null
  className?: string
  /** Show zoom / fit controls above the document. */
  showZoomControls?: boolean
  /** Start fitted to the container width (default) or at a fixed scale. */
  initialZoom?: number | 'fit'
}

function prunePreviewValues(value: unknown): unknown {
  if (value === null || value === undefined) return undefined
  if (typeof value === 'string') {
    const trimmed = value.trim()
    return trimmed.length > 0 ? trimmed : undefined
  }
  if (typeof value === 'number' || typeof value === 'boolean') return value
  if (Array.isArray(value)) {
    const next = value
      .map(prunePreviewValues)
      .filter(v => v !== undefined)
    return next.length > 0 ? next : undefined
  }
  if (typeof value === 'object') {
    const next: Record<string, unknown> = {}
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      const pruned = prunePreviewValues(v)
      if (pruned !== undefined) next[k] = pruned
    }
    return Object.keys(next).length > 0 ? next : undefined
  }
  return undefined
}

function renderDocxWithValues(blob: Blob, previewValues?: Record<string, unknown> | null): Promise<Blob> {
  if (!previewValues || Object.keys(previewValues).length === 0) return Promise.resolve(blob)

  return blob.arrayBuffer().then((buffer) => {
    try {
      const zip = new PizZip(buffer)
      const doc = new Docxtemplater(zip, {
        delimiters: { start: '[[', end: ']]' },
        paragraphLoop: true,
        linebreaks: true,
        parser: dottedPathParser,
        // Si no hi ha valor, mantenim el placeholder i evitem "undefined".
        nullGetter: (part: { raw?: string } | undefined) => {
          const raw = part?.raw?.trim()
          return raw ? `[[${raw}]]` : ''
        },
      })

      const safeValues = prunePreviewValues(previewValues)
      doc.render((safeValues && typeof safeValues === 'object') ? safeValues as Record<string, unknown> : {})
      return doc.getZip().generate({ type: 'blob' })
    } catch {
      // Fallback robust: si la plantilla no és parsejable, mostrem la vista prèvia original.
      return blob
    }
  })
}

export function DocxPreviewPane({
  storagePath,
  bucket = 'document-templates',
  fileBlob,
  previewValues,
  className,
  showZoomControls = false,
  initialZoom = 'fit',
}: DocxPreviewPaneProps) {
  const { t } = useTranslation('signing')
  const scrollRef = useRef<HTMLDivElement>(null)
  const containerRef = useRef<HTMLDivElement>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [rendered, setRendered] = useState(false)
  const [fitMode, setFitMode] = useState(initialZoom === 'fit')
  const [zoom, setZoom] = useState(typeof initialZoom === 'number' ? initialZoom : 1)
  const previewValuesKey = useMemo(
    () => JSON.stringify(previewValues ?? null),
    [previewValues],
  )

  const applyFitZoom = useCallback(() => {
    const scrollEl = scrollRef.current
    const page = containerRef.current?.querySelector('.docx-page') as HTMLElement | null
    if (!scrollEl || !page) return
    const natural = page.offsetWidth || page.scrollWidth
    if (natural <= 0) return
    const available = Math.max(120, scrollEl.clientWidth - 24)
    const next = Math.min(1, available / natural)
    setZoom(Number(next.toFixed(3)))
  }, [])

  useEffect(() => {
    const hasSrc = fileBlob || storagePath
    if (!hasSrc) { setLoading(false); setRendered(false); return }
    let cancelled = false
    setLoading(true)
    setError(null)
    setRendered(false)
    if (containerRef.current) containerRef.current.innerHTML = ''

    ;(async () => {
      try {
        let blob: Blob
        if (fileBlob) {
          blob = fileBlob
        } else {
          const { data, error: dlErr } = await supabase.storage
            .from(bucket)
            .download(storagePath!)
          if (dlErr || !data) {
            const missing = !data || /not found/i.test(dlErr?.message ?? '')
            throw new Error(
              missing
                ? t(
                    'locale.previewMissingFile',
                    'El fitxer DOCX no és al Storage. Si és una plantilla de plataforma, cal pujar els seeds (scripts/generate-commercial-docx-seed.mjs).',
                  )
                : (dlErr?.message ?? t('locale.previewLoadError', 'Error en carregar la vista prèvia')),
            )
          }
          blob = data
        }

        const previewBlob = await renderDocxWithValues(
          blob,
          previewValuesKey === 'null' ? null : (JSON.parse(previewValuesKey) as Record<string, unknown>),
        )

        if (!cancelled && containerRef.current) {
          await renderAsync(previewBlob, containerRef.current, containerRef.current, {
            ignoreFonts: false,
            breakPages: true,
            useBase64URL: true,
          })
          if (!cancelled) setRendered(true)
        }
      } catch (err) {
        if (!cancelled) setError(err instanceof Error ? err.message : t('locale.previewLoadError', 'Error en carregar la vista prèvia'))
      } finally {
        if (!cancelled) setLoading(false)
      }
    })()

    return () => { cancelled = true }
  }, [storagePath, bucket, fileBlob, previewValuesKey, t])

  useEffect(() => {
    if (!rendered || !fitMode) return
    applyFitZoom()
    const scrollEl = scrollRef.current
    if (!scrollEl || typeof ResizeObserver === 'undefined') return
    const ro = new ResizeObserver(() => {
      if (fitMode) applyFitZoom()
    })
    ro.observe(scrollEl)
    return () => ro.disconnect()
  }, [rendered, fitMode, applyFitZoom])

  return (
    <div className={cn('flex min-h-0 flex-col', className)}>
      {showZoomControls ? (
        <div className="mb-2 flex shrink-0 items-center justify-end gap-1">
          <Button
            type="button"
            variant="outline"
            size="icon"
            className="h-7 w-7"
            disabled={loading || !rendered || zoom <= DOCX_ZOOM_MIN}
            onClick={() => {
              setFitMode(false)
              setZoom((z) => Math.max(DOCX_ZOOM_MIN, Number((z - DOCX_ZOOM_STEP).toFixed(2))))
            }}
            aria-label={t('locale.previewZoomOut', 'Allunyar')}
          >
            <Minus className="h-3.5 w-3.5" />
          </Button>
          <span className="min-w-12 text-center text-[11px] tabular-nums text-muted-foreground">
            {Math.round(zoom * 100)}%
          </span>
          <Button
            type="button"
            variant="outline"
            size="icon"
            className="h-7 w-7"
            disabled={loading || !rendered || zoom >= DOCX_ZOOM_MAX}
            onClick={() => {
              setFitMode(false)
              setZoom((z) => Math.min(DOCX_ZOOM_MAX, Number((z + DOCX_ZOOM_STEP).toFixed(2))))
            }}
            aria-label={t('locale.previewZoomIn', 'Apropar')}
          >
            <Plus className="h-3.5 w-3.5" />
          </Button>
          <Button
            type="button"
            variant="outline"
            size="sm"
            className="h-7 px-2 text-[11px]"
            disabled={loading || !rendered}
            onClick={() => {
              setFitMode(true)
              applyFitZoom()
            }}
            aria-label={t('locale.previewZoomFit', 'Ajustar a l’amplada')}
          >
            <Maximize2 className="mr-1 h-3.5 w-3.5" />
            {t('locale.previewZoomFitShort', 'Ajustar')}
          </Button>
        </div>
      ) : null}

      {loading && (
        <div className="flex items-center justify-center py-8 text-sm text-muted-foreground animate-pulse">
          {t('locale.previewLoading', 'Carregant vista prèvia...')}
        </div>
      )}
      {error && (
        <div className="rounded-lg border border-destructive/30 bg-destructive/5 text-destructive text-sm px-4 py-3">
          {error}
        </div>
      )}

      <div
        ref={scrollRef}
        className={cn(
          'min-h-0 flex-1 overflow-auto rounded-md bg-muted/20',
          !loading && !error && 'border border-border/60',
        )}
      >
        <div
          className="inline-block min-w-full p-3"
          style={{ zoom }}
        >
          <div
            ref={containerRef}
            className="docx-preview mx-auto [&_.docx-wrapper]:bg-transparent! [&_.docx-wrapper]:p-0! [&_.docx-wrapper]:shadow-none! [&_.docx-page]:mb-4! [&_.docx-page]:shadow-sm!"
          />
        </div>
      </div>
    </div>
  )
}

// ─── Modal: DOCX preview in a dialog ─────────────────────────────────────────

interface DocxPreviewModalProps {
  open:        boolean
  onClose:     () => void
  storagePath: string
  fileName?:   string
  bucket?:     string
  previewValues?: Record<string, unknown> | null
}

export function DocxPreviewModal({ open, onClose, storagePath, fileName, bucket = 'document-templates', previewValues }: DocxPreviewModalProps) {
  const { t }        = useTranslation('signing')
  const containerRef = useRef<HTMLDivElement>(null)
  const [loading, setLoading] = useState(true)
  const [error,   setError]   = useState<string | null>(null)

  useEffect(() => {
    if (!open || !storagePath) return
    let cancelled = false
    setLoading(true)
    setError(null)
    if (containerRef.current) containerRef.current.innerHTML = ''

    ;(async () => {
      try {
        const { data, error: dlErr } = await supabase.storage
          .from(bucket)
          .download(storagePath)
        if (dlErr || !data) {
          const missing = !data || /not found/i.test(dlErr?.message ?? '')
          throw new Error(
            missing
              ? t(
                  'locale.previewMissingFile',
                  'El fitxer DOCX no és al Storage. Si és una plantilla de plataforma, cal pujar els seeds (scripts/generate-commercial-docx-seed.mjs).',
                )
              : (dlErr?.message ?? t('locale.previewLoadError', 'Error en carregar la vista prèvia')),
          )
        }
        const previewBlob = await renderDocxWithValues(data, previewValues)

        if (!cancelled && containerRef.current) {
          await renderAsync(previewBlob, containerRef.current, containerRef.current, {
            ignoreFonts: false,
            breakPages:  true,
            useBase64URL: true,
          })
        }
      } catch (err) {
        if (!cancelled) setError(err instanceof Error ? err.message : t('locale.previewLoadError', 'Error en carregar la vista prèvia'))
      } finally {
        if (!cancelled) setLoading(false)
      }
    })()

    return () => { cancelled = true }
  }, [open, storagePath, bucket, previewValues, t])

  return (
    <Dialog open={open} onOpenChange={v => { if (!v) onClose() }}>
      <DialogContent className="max-w-4xl w-full max-h-[90vh] flex flex-col gap-0 p-0">
        <DialogHeader className="px-6 pt-6 pb-3 shrink-0">
          <DialogTitle className="text-base font-semibold">
            {fileName ?? t('locale.previewTitle', 'Vista prèvia del document')}
          </DialogTitle>
        </DialogHeader>

        <div className="flex min-h-0 flex-1 flex-col px-6 pb-6 pt-2">
          {loading && (
            <div className="flex items-center justify-center py-16 text-sm text-muted-foreground animate-pulse">
              {t('locale.previewLoading', 'Carregant vista prèvia...')}
            </div>
          )}
          {error && (
            <div className="rounded-lg border border-destructive/30 bg-destructive/5 text-destructive text-sm px-4 py-3">
              {error}
            </div>
          )}
          <div className="min-h-0 flex-1 overflow-auto rounded-md border border-border/60 bg-muted/20 p-3">
            <div
              ref={containerRef}
              className="docx-preview mx-auto [&_.docx-wrapper]:bg-transparent! [&_.docx-wrapper]:p-0! [&_.docx-wrapper]:shadow-none! [&_.docx-page]:mb-4! [&_.docx-page]:shadow-sm!"
            />
          </div>
        </div>
      </DialogContent>
    </Dialog>
  )
}
