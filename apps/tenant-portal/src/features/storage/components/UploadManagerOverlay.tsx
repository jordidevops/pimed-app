import { useTranslation } from 'react-i18next'
import { useUploadManager, type UploadItem, type UploadStatus } from '../contexts/UploadManagerContext'
import { formatBytes } from '../utils/fileUtils'

// ─── Localised error message ──────────────────────────────────────────────────
// The upload pipeline stores error codes (e.g. 'mime_type_not_allowed').
// This maps them to user-friendly strings so the overlay stays clean.

function resolveError(code: string | null, t: (k: string, fb: string) => string): string {
  if (!code) return t('storage.status.error', 'Error')
  if (code === 'mime_type_not_allowed') return t('storage.mime.not_allowed', 'Tipus de fitxer no permès')
  if (code === 'mime_type_unknown') return t('storage.mime.unknown', 'Tipus de fitxer desconegut')
  return code
}

// ─── Stage label ──────────────────────────────────────────────────────────────

function stageLabel(status: UploadStatus, stage: string | undefined, t: (k: string, fb: string) => string): string {
  if (status === 'done') return t('storage.status.done', 'Completat')
  if (status === 'error') return t('storage.status.error', 'Error')
  if (status === 'aborted') return t('storage.explorer.upload_cancelled', 'Cancel·lat')
  if (status === 'queued') return t('storage.explorer.upload_queued', 'En cua...')
  switch (stage) {
    case 'requesting': return t('storage.status.requesting', 'Preparant pujada...')
    case 'uploading': return t('storage.explorer.upload_uploading', 'Pujant...')
    case 'confirming': return t('storage.status.confirming', 'Verificant fitxer...')
    default: return t('storage.explorer.upload_uploading', 'Pujant...')
  }
}

function statusColor(status: UploadStatus): string {
  switch (status) {
    case 'done': return 'bg-green-500'
    case 'error': return 'bg-red-500'
    case 'aborted': return 'bg-muted-foreground/60'
    default: return 'bg-indigo-500'
  }
}

// ─── Single upload row ────────────────────────────────────────────────────────

function UploadRow({ item }: { item: UploadItem }) {
  const { t } = useTranslation('storage')
  const { abortUpload, removeUpload } = useUploadManager()

  const pct = item.progress?.percent ?? 0
  const finished = item.status === 'done' || item.status === 'error' || item.status === 'aborted'

  return (
    <div className="px-3 py-2 flex flex-col gap-1">
      <div className="flex items-center gap-2 min-w-0">
        <span className="text-sm truncate flex-1 text-foreground font-medium">{item.fileName}</span>
        {!finished && (
          <button
            type="button"
            onClick={() => abortUpload(item.id)}
            className="text-xs text-muted-foreground hover:text-red-500 shrink-0 transition"
            aria-label={t('storage.actions.cancel', 'Cancel·lar')}
          >
            ✕
          </button>
        )}
        {finished && (
          <button
            type="button"
            onClick={() => removeUpload(item.id)}
            className="text-xs text-muted-foreground hover:text-foreground shrink-0 transition"
            aria-label={t('storage.explorer.upload_dismiss', 'Tancar')}
          >
            ✕
          </button>
        )}
      </div>

      {/* Progress bar */}
      <div className="h-1 rounded-full bg-muted overflow-hidden">
        <div
          className={`h-full rounded-full transition-all ${statusColor(item.status)}`}
          style={{ width: `${finished && item.status !== 'done' ? 100 : pct}%` }}
        />
      </div>

      <div className="flex items-center justify-between text-[11px] text-muted-foreground">
        <span>{stageLabel(item.status, item.progress?.stage, t)}</span>
        {item.status === 'uploading' && item.progress && (
          <span>{formatBytes(item.progress.loaded)} / {formatBytes(item.progress.total)}</span>
        )}
        {item.status === 'error' && item.error && (
          <span className="text-red-500 truncate max-w-[180px]">{resolveError(item.error, t)}</span>
        )}
      </div>
    </div>
  )
}

// ─── Overlay ──────────────────────────────────────────────────────────────────

export function UploadManagerOverlay() {
  const { t } = useTranslation('storage')
  const { items, minimised, clearDone, toggleMinimise } = useUploadManager()

  if (items.length === 0) return null

  const activeCount = items.filter((i) => i.status === 'queued' || i.status === 'uploading').length
  const doneCount = items.filter((i) => i.status === 'done').length

  return (
    <div className="fixed bottom-4 right-4 z-50 w-80 max-h-[50vh] flex flex-col rounded-xl border border-border bg-card shadow-xl overflow-hidden">
      {/* Header */}
      <div
        className="flex items-center justify-between px-3 py-2 bg-muted/50 border-b border-border cursor-pointer"
        onClick={toggleMinimise}
      >
        <span className="text-xs font-semibold text-foreground">
          {activeCount > 0
            ? t('storage.explorer.upload_active', 'Pujant {{count}} fitxers...', { count: activeCount })
            : t('storage.explorer.upload_complete', 'Pujades completades')}
        </span>
        <div className="flex items-center gap-1.5">
          {doneCount > 0 && (
            <button
              type="button"
              onClick={(e) => { e.stopPropagation(); clearDone() }}
              className="text-[10px] text-muted-foreground hover:text-foreground transition"
            >
              {t('storage.explorer.upload_clear', 'Netejar')}
            </button>
          )}
          <span className="text-muted-foreground text-xs select-none">{minimised ? '▲' : '▼'}</span>
        </div>
      </div>

      {/* List */}
      {!minimised && (
        <div className="flex-1 overflow-y-auto divide-y divide-border">
          {items.map((item) => (
            <UploadRow key={item.id} item={item} />
          ))}
        </div>
      )}
    </div>
  )
}
