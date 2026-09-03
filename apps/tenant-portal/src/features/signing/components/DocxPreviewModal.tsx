import { useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { renderAsync } from 'docx-preview'
import PizZip from 'pizzip'
import Docxtemplater from 'docxtemplater'
import { supabase } from '@/lib/supabase'
import {
  Dialog, DialogContent, DialogHeader, DialogTitle,
} from '@/components/ui/dialog'

// ─── Pane: inline DOCX preview (no dialog) ───────────────────────────────────

interface DocxPreviewPaneProps {
  storagePath?: string | null
  bucket?: string
  /** Fitxer local (p.ex. acabat de seleccionar, no desat yet). Prioritari sobre storagePath. */
  fileBlob?: Blob | null
  /** Valors per substituir tags DOCX en viu (si existeixen). */
  previewValues?: Record<string, unknown> | null
  className?: string
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

export function DocxPreviewPane({ storagePath, bucket = 'document-templates', fileBlob, previewValues, className }: DocxPreviewPaneProps) {
  const { t } = useTranslation('signing')
  const containerRef = useRef<HTMLDivElement>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    const hasSrc = fileBlob || storagePath
    if (!hasSrc) { setLoading(false); return }
    let cancelled = false
    setLoading(true)
    setError(null)
    if (containerRef.current) containerRef.current.innerHTML = ''

    ;(async () => {
      try {
        let blob: Blob
        if (fileBlob) {
          blob = fileBlob
        } else {
          const { data: urlData, error: urlErr } = await supabase.storage
            .from(bucket)
            .createSignedUrl(storagePath!, 120)
          if (urlErr || !urlData) throw new Error(urlErr?.message ?? 'URL error')
          const res = await fetch(urlData.signedUrl)
          if (!res.ok) throw new Error(`HTTP ${res.status}`)
          blob = await res.blob()
        }

        // Si hi ha valors, genera una còpia renderitzada per a la vista prèvia.
        const previewBlob = await renderDocxWithValues(blob, previewValues)

        if (!cancelled && containerRef.current) {
          await renderAsync(previewBlob, containerRef.current, containerRef.current, {
            ignoreFonts: false,
            breakPages: true,
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
  }, [storagePath, bucket, fileBlob, previewValues])

  return (
    <div className={`overflow-x-hidden ${className ?? ''}`}>
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
      <div ref={containerRef} className="docx-preview overflow-x-hidden [&_.docx-wrapper]:bg-transparent! [&_.docx-wrapper]:p-0! [&_.docx-wrapper]:max-w-full! [&_.docx-page]:max-w-full!" />
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
}

export function DocxPreviewModal({ open, onClose, storagePath, fileName, bucket = 'document-templates' }: DocxPreviewModalProps) {
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
        const { data: urlData, error: urlErr } = await supabase.storage
          .from(bucket)
          .createSignedUrl(storagePath, 120)
        if (urlErr || !urlData) throw new Error(urlErr?.message ?? 'URL error')

        const res = await fetch(urlData.signedUrl)
        if (!res.ok) throw new Error(`HTTP ${res.status}`)
        const blob = await res.blob()

        if (!cancelled && containerRef.current) {
          await renderAsync(blob, containerRef.current, containerRef.current, {
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
  }, [open, storagePath, bucket])

  return (
    <Dialog open={open} onOpenChange={v => { if (!v) onClose() }}>
      <DialogContent className="max-w-4xl w-full max-h-[90vh] flex flex-col gap-0 p-0">
        <DialogHeader className="px-6 pt-6 pb-3 shrink-0">
          <DialogTitle className="text-base font-semibold">
            {fileName ?? t('locale.previewTitle', 'Vista prèvia del document')}
          </DialogTitle>
        </DialogHeader>

        <div className="flex-1 overflow-y-auto px-6 pt-6 pb-6 min-h-0">
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
          {/* docx-preview renders into this div */}
          <div ref={containerRef} className="docx-preview overflow-x-hidden [&_.docx-wrapper]:bg-transparent! [&_.docx-wrapper]:p-0! [&_.docx-wrapper]:max-w-full! [&_.docx-page]:max-w-full!" />
        </div>
      </DialogContent>
    </Dialog>
  )
}
