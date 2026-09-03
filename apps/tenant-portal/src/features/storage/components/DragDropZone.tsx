import { useCallback, useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { validateMimeType } from '../utils/fileUtils'

interface DragDropZoneProps {
  onDrop: (files: File[]) => void
  disabled?: boolean
  children: ReactNode
}

export function DragDropZone({ onDrop, disabled, children }: DragDropZoneProps) {
  const { t } = useTranslation('storage')
  const [dragOver, setDragOver] = useState(false)
  // Number of files rejected on last drop (cleared automatically after 3 s)
  const [rejectedCount, setRejectedCount] = useState(0)

  const handleDragOver = useCallback(
    (e: React.DragEvent) => {
      e.preventDefault()
      e.stopPropagation()
      if (!disabled) setDragOver(true)
    },
    [disabled],
  )

  const handleDragLeave = useCallback((e: React.DragEvent) => {
    e.preventDefault()
    e.stopPropagation()
    setDragOver(false)
  }, [])

  const handleDrop = useCallback(
    (e: React.DragEvent) => {
      e.preventDefault()
      e.stopPropagation()
      setDragOver(false)
      if (disabled) return

      const all = Array.from(e.dataTransfer.files)
      // ── MIME validation: split files into accepted / rejected ─────────────
      const accepted: File[] = []
      let rejected = 0
      for (const file of all) {
        if (validateMimeType(file) === null) {
          accepted.push(file)
        } else {
          rejected++
        }
      }

      if (rejected > 0) {
        setRejectedCount(rejected)
        setTimeout(() => setRejectedCount(0), 3000)
      }

      if (accepted.length > 0) onDrop(accepted)
    },
    [onDrop, disabled],
  )

  return (
    <div
      className="relative flex-1 flex flex-col min-h-0"
      onDragOver={handleDragOver}
      onDragLeave={handleDragLeave}
      onDrop={handleDrop}
    >
      {children}

      {/* Drop overlay */}
      {dragOver && (
        <div className="absolute inset-0 z-30 flex items-center justify-center bg-indigo-50/80 border-2 border-dashed border-indigo-400 rounded-xl pointer-events-none">
          <div className="flex flex-col items-center gap-2 text-indigo-600">
            <svg className="h-10 w-10" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.5} aria-hidden>
              <path strokeLinecap="round" strokeLinejoin="round" d="M12 16V4m0 0L8 8m4-4 4 4M4 14v4a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-4" />
            </svg>
            <span className="text-sm font-semibold">
              {t('storage.explorer.drop_hint', 'Deixa anar els fitxers per pujar-los')}
            </span>
          </div>
        </div>
      )}

      {/* Rejected files toast */}
      {rejectedCount > 0 && (
        <div className="absolute bottom-4 left-1/2 -translate-x-1/2 z-40 px-4 py-2 rounded-xl bg-red-600 text-white text-sm font-medium shadow-lg pointer-events-none">
          {t('storage.mime.drop_rejected', '{{count}} fitxer(s) rebutjats: tipus no permès', { count: rejectedCount })}
        </div>
      )}
    </div>
  )
}
