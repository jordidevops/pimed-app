import { useState, useRef, useCallback, useEffect } from 'react'
import { useTranslation } from 'react-i18next'
import { Document, Page, pdfjs } from 'react-pdf'
import { Trash2, ChevronLeft, ChevronRight } from 'lucide-react'
import { Button } from '@/components/ui/button'
import type { PdfField, PdfFieldType } from '../types/documentFields'
import 'react-pdf/dist/Page/AnnotationLayer.css'
import 'react-pdf/dist/Page/TextLayer.css'

// Configurar worker de pdfjs (react-pdf v10+)
pdfjs.GlobalWorkerOptions.workerSrc = new URL(
  'pdfjs-dist/build/pdf.worker.min.mjs',
  import.meta.url,
).toString()

// ─── Constants ────────────────────────────────────────────────────────────────

const FIELD_COLORS: Record<PdfFieldType, string> = {
  signature: 'bg-indigo-500/30 border-indigo-600',
  initials:  'bg-purple-500/30 border-purple-600',
  text:      'bg-sky-500/30 border-sky-600',
  date:      'bg-amber-500/30 border-amber-600',
  checkbox:  'bg-green-500/30 border-green-600',
}

const FIELD_TYPES: PdfFieldType[] = ['signature', 'initials', 'text', 'date', 'checkbox']

// ─── Props ────────────────────────────────────────────────────────────────────

interface PdfFieldEditorProps {
  /** URL o Blob del PDF a editar */
  pdfSource:    string | Blob | null
  /** Llista de camps actuals */
  fields:       PdfField[]
  onChange:     (fields: PdfField[]) => void
  /** Rols disponibles per assignar als camps (opcional) */
  signingRoles?: string[]
}

// ─── Component ────────────────────────────────────────────────────────────────

export function PdfFieldEditor({ pdfSource, fields, onChange, signingRoles = [] }: PdfFieldEditorProps) {
  const { t } = useTranslation('signing')

  const [numPages, setNumPages]     = useState<number>(0)
  const [currentPage, setCurrentPage] = useState(1)
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [activeType, setActiveType] = useState<PdfFieldType>('signature')
  const [activeRole, setActiveRole] = useState<string>('')
  const [isDrawing, setIsDrawing]   = useState(false)
  const [drawStart, setDrawStart]   = useState<{ x: number; y: number } | null>(null)
  const [drawCurrent, setDrawCurrent] = useState<{ x: number; y: number } | null>(null)
  const pageContainerRef = useRef<HTMLDivElement>(null)

  const pageFields = fields.filter(f => f.page === currentPage)

  // Netejar selecció en canviar de pàgina
  useEffect(() => { setSelectedId(null) }, [currentPage])

  // ── Mouse events per dibuixar nous camps ──────────────────────────────────

  function getRelativePosition(e: React.MouseEvent) {
    const rect = pageContainerRef.current?.getBoundingClientRect()
    if (!rect) return null
    return {
      x: ((e.clientX - rect.left) / rect.width)  * 100,
      y: ((e.clientY - rect.top)  / rect.height) * 100,
    }
  }

  function onMouseDown(e: React.MouseEvent) {
    if (e.button !== 0) return
    const pos = getRelativePosition(e)
    if (!pos) return
    // Si cliquem sobre un camp existent, el seleccionem i no dibuixem
    const clickedField = pageFields.find(f => {
      return pos.x >= f.x && pos.x <= f.x + f.w && pos.y >= f.y && pos.y <= f.y + f.h
    })
    if (clickedField) {
      setSelectedId(clickedField.id)
      return
    }
    setSelectedId(null)
    setIsDrawing(true)
    setDrawStart(pos)
    setDrawCurrent(pos)
  }

  function onMouseMove(e: React.MouseEvent) {
    if (!isDrawing || !drawStart) return
    const pos = getRelativePosition(e)
    if (pos) setDrawCurrent(pos)
  }

  function onMouseUp(e: React.MouseEvent) {
    if (!isDrawing || !drawStart) return
    setIsDrawing(false)
    const pos = getRelativePosition(e)
    if (!pos) return

    const x = Math.min(drawStart.x, pos.x)
    const y = Math.min(drawStart.y, pos.y)
    const w = Math.abs(pos.x - drawStart.x)
    const h = Math.abs(pos.y - drawStart.y)

    // Ignorar drags massa petits (< 2% de la pàgina)
    if (w < 2 || h < 1) {
      setDrawStart(null)
      setDrawCurrent(null)
      return
    }

    const newField: PdfField = {
      id:    crypto.randomUUID(),
      page:  currentPage,
      x:     parseFloat(x.toFixed(2)),
      y:     parseFloat(y.toFixed(2)),
      w:     parseFloat(w.toFixed(2)),
      h:     parseFloat(h.toFixed(2)),
      type:  activeType,
      role:  activeRole || null,
      label: null,
      required: true,
    }

    onChange([...fields, newField])
    setSelectedId(newField.id)
    setDrawStart(null)
    setDrawCurrent(null)
  }

  // ── Operacions sobre camps ─────────────────────────────────────────────────

  const deleteField = useCallback((id: string) => {
    onChange(fields.filter(f => f.id !== id))
    setSelectedId(prev => prev === id ? null : prev)
  }, [fields, onChange])

  function updateField(id: string, patch: Partial<PdfField>) {
    onChange(fields.map(f => f.id === id ? { ...f, ...patch } : f))
  }

  const selectedField = fields.find(f => f.id === selectedId) ?? null

  // ── Dibuix en curs ────────────────────────────────────────────────────────

  const drawBox = isDrawing && drawStart && drawCurrent ? {
    x: Math.min(drawStart.x, drawCurrent.x),
    y: Math.min(drawStart.y, drawCurrent.y),
    w: Math.abs(drawCurrent.x - drawStart.x),
    h: Math.abs(drawCurrent.y - drawStart.y),
  } : null

  // ─────────────────────────────────────────────────────────────────────────────

  return (
    <div className="flex gap-4 h-full min-h-0">

      {/* Panell esquerre: controls */}
      <div className="w-52 shrink-0 space-y-3">

        {/* Tipus de camp */}
        <div>
          <p className="text-xs font-medium text-muted-foreground mb-1.5 uppercase tracking-wide">
            {t('pdfEditor.fieldType', 'Tipus de camp')}
          </p>
          <div className="space-y-1">
            {FIELD_TYPES.map(type => (
              <button
                key={type}
                type="button"
                onClick={() => setActiveType(type)}
                className={`w-full text-left px-2.5 py-1.5 rounded-md text-xs font-medium transition-colors ${
                  activeType === type
                    ? 'bg-indigo-600 text-white'
                    : 'hover:bg-accent'
                }`}
              >
                {t(`pdfEditor.type.${type}`, type)}
              </button>
            ))}
          </div>
        </div>

        {/* Rol de signant */}
        {signingRoles.length > 0 && (
          <div>
            <p className="text-xs font-medium text-muted-foreground mb-1.5 uppercase tracking-wide">
              {t('pdfEditor.role', 'Rol assignat')}
            </p>
            <select
              value={activeRole}
              onChange={e => setActiveRole(e.target.value)}
              className="w-full text-xs border rounded-md px-2 py-1.5 bg-background"
            >
              <option value="">{t('pdfEditor.roleAny', 'Qualsevol')}</option>
              {signingRoles.map(r => (
                <option key={r} value={r}>{r}</option>
              ))}
            </select>
          </div>
        )}

        {/* Camp seleccionat — propietats */}
        {selectedField && (
          <div className="border rounded-lg p-2.5 space-y-2 bg-muted/30">
            <p className="text-xs font-semibold">{t('pdfEditor.selectedField', 'Camp seleccionat')}</p>

            <div className="space-y-1">
              <label className="text-[10px] text-muted-foreground">{t('pdfEditor.fieldLabel', 'Etiqueta')}</label>
              <input
                type="text"
                value={selectedField.label ?? ''}
                onChange={e => updateField(selectedField.id, { label: e.target.value || null })}
                className="w-full text-xs border rounded px-2 py-1 bg-background"
                placeholder={t('pdfEditor.fieldLabelPlaceholder', 'Opcional')}
              />
            </div>

            {signingRoles.length > 0 && (
              <div className="space-y-1">
                <label className="text-[10px] text-muted-foreground">{t('pdfEditor.fieldRole', 'Rol')}</label>
                <select
                  value={selectedField.role ?? ''}
                  onChange={e => updateField(selectedField.id, { role: e.target.value || null })}
                  className="w-full text-xs border rounded px-2 py-1 bg-background"
                >
                  <option value="">{t('pdfEditor.roleAny', 'Qualsevol')}</option>
                  {signingRoles.map(r => (
                    <option key={r} value={r}>{r}</option>
                  ))}
                </select>
              </div>
            )}

            <Button
              type="button"
              variant="destructive"
              size="sm"
              className="w-full h-7 text-xs"
              onClick={() => deleteField(selectedField.id)}
            >
              <Trash2 className="h-3 w-3 mr-1" />
              {t('pdfEditor.deleteField', 'Eliminar camp')}
            </Button>
          </div>
        )}

        {/* Resum */}
        <p className="text-xs text-muted-foreground">
          {t('pdfEditor.fieldCount', '{{n}} camp(s)', { n: fields.length })}
        </p>
      </div>

      {/* Panell dret: visualitzador PDF + camps */}
      <div className="flex-1 flex flex-col gap-2 min-h-0">

        {/* Navegació de pàgines */}
        {numPages > 1 && (
          <div className="flex items-center gap-2 justify-center">
            <Button
              type="button"
              variant="outline"
              size="icon"
              className="h-7 w-7"
              disabled={currentPage <= 1}
              onClick={() => setCurrentPage(p => p - 1)}
            >
              <ChevronLeft className="h-3.5 w-3.5" />
            </Button>
            <span className="text-xs text-muted-foreground">
              {t('pdfEditor.page', 'Pàgina {{current}} de {{total}}', { current: currentPage, total: numPages })}
            </span>
            <Button
              type="button"
              variant="outline"
              size="icon"
              className="h-7 w-7"
              disabled={currentPage >= numPages}
              onClick={() => setCurrentPage(p => p + 1)}
            >
              <ChevronRight className="h-3.5 w-3.5" />
            </Button>
          </div>
        )}

        {/* Contenidor del PDF amb overlay */}
        <div
          ref={pageContainerRef}
          className="relative overflow-hidden rounded-lg border bg-white cursor-crosshair select-none"
          onMouseDown={onMouseDown}
          onMouseMove={onMouseMove}
          onMouseUp={onMouseUp}
        >
          {pdfSource ? (
            <Document
              file={pdfSource}
              onLoadSuccess={({ numPages }) => setNumPages(numPages)}
              loading={
                <div className="flex items-center justify-center p-8 text-muted-foreground text-sm">
                  {t('pdfEditor.loading', 'Carregant PDF...')}
                </div>
              }
              error={
                <div className="flex items-center justify-center p-8 text-red-500 text-sm">
                  {t('pdfEditor.loadError', 'Error en carregar el PDF')}
                </div>
              }
            >
              <Page
                pageNumber={currentPage}
                width={pageContainerRef.current?.clientWidth ?? 600}
                renderTextLayer={false}
                renderAnnotationLayer={false}
              />
            </Document>
          ) : (
            <div className="flex items-center justify-center p-16 text-muted-foreground text-sm">
              {t('pdfEditor.noFile', 'Selecciona un fitxer PDF')}
            </div>
          )}

          {/* Overlay de camps existents */}
          {pageFields.map(field => (
            <div
              key={field.id}
              className={`absolute border-2 rounded ${FIELD_COLORS[field.type]} ${
                selectedId === field.id ? 'ring-2 ring-offset-1 ring-indigo-600' : ''
              }`}
              style={{
                left:   `${field.x}%`,
                top:    `${field.y}%`,
                width:  `${field.w}%`,
                height: `${field.h}%`,
              }}
            >
              <span className="absolute inset-0 flex items-center justify-center text-[9px] font-medium text-center leading-tight px-0.5 overflow-hidden">
                {field.label ?? t(`pdfEditor.type.${field.type}`, field.type)}
                {field.role && ` (${field.role})`}
              </span>
            </div>
          ))}

          {/* Dibuix en curs */}
          {drawBox && (
            <div
              className={`absolute border-2 border-dashed rounded pointer-events-none ${FIELD_COLORS[activeType]}`}
              style={{
                left:   `${drawBox.x}%`,
                top:    `${drawBox.y}%`,
                width:  `${drawBox.w}%`,
                height: `${drawBox.h}%`,
              }}
            />
          )}
        </div>

        <p className="text-[10px] text-muted-foreground text-center">
          {t('pdfEditor.hint', 'Fes clic i arrossega per afegir un camp. Clica un camp per seleccionar-lo.')}
        </p>
      </div>
    </div>
  )
}
