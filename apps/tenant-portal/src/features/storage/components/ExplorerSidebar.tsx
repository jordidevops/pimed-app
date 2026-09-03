import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useExplorer, type ExplorerView } from '../contexts/ExplorerContext'
import { formatBytes, formatDateTime, getFileEmoji } from '../utils/fileUtils'
import { QuotaWidget } from './QuotaWidget'
import { GetUrlModal } from './GetUrlModal'
import { getFileUrl } from '../api/storageService'
import { useStorageDrives } from '../api/useStorageDrives'
import { FolderTree } from './FolderTree'

interface ExplorerSidebarProps {
  tenantId: string | undefined
  width: number
  hideFieldWork?: boolean
}

const views: { key: ExplorerView; icon: string; labelKey: string; labelFallback: string }[] = [
  { key: 'files', icon: '📁', labelKey: 'storage.explorer.nav_files', labelFallback: 'Tots els fitxers' },
  { key: 'starred', icon: '⭐', labelKey: 'storage.explorer.nav_starred', labelFallback: 'Destacats' },
  { key: 'trash', icon: '🗑️', labelKey: 'storage.explorer.nav_trash', labelFallback: 'Paperera' },
]

export function ExplorerSidebar({ tenantId, width, hideFieldWork }: ExplorerSidebarProps) {
  const { t } = useTranslation('storage')
  const { state, setView, setActiveDrive } = useExplorer()
  const preview = state.sidebarPreview
  const { data: byosDrives = [] } = useStorageDrives(tenantId)

  // Fetch signed URL when the preview changes
  const [signedUrl, setSignedUrl] = useState<string | null>(null)
  const [isPreviewLoading, setIsPreviewLoading] = useState(false)
  const [textPreview, setTextPreview] = useState<string | null>(null)
  const [isTextPreviewLoading, setIsTextPreviewLoading] = useState(false)

  // Download + share actions
  const [isDownloading, setIsDownloading] = useState(false)
  const [shareModalOpen, setShareModalOpen] = useState(false)

  // Reset action state whenever the selected file changes
  useEffect(() => {
    setShareModalOpen(false)
    setIsDownloading(false)
  }, [preview?.id])

  async function handleDownload() {
    if (!preview?.id || !tenantId) return
    setIsDownloading(true)
    try {
      const { url } = await getFileUrl(preview.id, 300, tenantId, true)
      window.open(url, '_blank', 'noopener,noreferrer')
    } catch {
      // Silent fail — signed URL errors are rare and transient
    } finally {
      setIsDownloading(false)
    }
  }

  const mime = preview?.mimeType ?? ''
  const isImage = mime.startsWith('image/')
  const isPdf = mime === 'application/pdf'
  const isText = mime.startsWith('text/')
  const needsSignedUrl = isImage || isPdf || isText

  useEffect(() => {
    if (!preview?.id || !preview?.storageKey || !tenantId || !needsSignedUrl) {
      setSignedUrl(null)
      setIsPreviewLoading(false)
      return
    }
    let cancelled = false
    setIsPreviewLoading(true)
    // Use backend edge function so preview works for both internal storage and BYOS (R2/S3/GCS).
    getFileUrl(preview.id, 120, tenantId, false)
      .then(({ url }) => {
        if (cancelled) return
        setSignedUrl(url ?? null)
        setIsPreviewLoading(false)
      })
      .catch(() => {
        if (cancelled) return
        setSignedUrl(null)
        setIsPreviewLoading(false)
      })
    return () => { cancelled = true }
  }, [preview?.id, tenantId, needsSignedUrl])

  useEffect(() => {
    if (!isText || !signedUrl) {
      setTextPreview(null)
      setIsTextPreviewLoading(false)
      return
    }

    let cancelled = false
    setIsTextPreviewLoading(true)

    fetch(signedUrl)
      .then((res) => (res.ok ? res.text() : Promise.reject(new Error('text_fetch_failed'))))
      .then((content) => {
        if (cancelled) return
        setTextPreview(content.slice(0, 3000))
        setIsTextPreviewLoading(false)
      })
      .catch(() => {
        if (cancelled) return
        setTextPreview(null)
        setIsTextPreviewLoading(false)
      })

    return () => { cancelled = true }
  }, [isText, signedUrl])

  return (
    <aside
      className="flex flex-col border-r border-border bg-card shrink-0 h-full overflow-hidden"
      style={{ width }}
    >
      <nav className="flex-1 px-2 py-4 space-y-0.5 overflow-y-auto" aria-label={t('storage.explorer.sidebar_label', 'Navegació de fitxers')}>

        {/* Drive switcher */}
        {byosDrives.length > 0 && (
          <div className="mb-2 pb-2 border-b border-border">
            <p className="px-3 mb-1 text-[10px] font-semibold uppercase tracking-wider text-muted-foreground">
              {t('storage.drives.nav_label', 'Unitats')}
            </p>
            {/* App Drive */}
            <button
              type="button"
              onClick={() => setActiveDrive(null)}
              className={`w-full flex items-center gap-2 px-3 py-1.5 rounded-lg text-xs font-medium transition-colors select-none ${
                state.activeDriveId === null
                  ? 'bg-emerald-50 text-emerald-700'
                  : 'text-muted-foreground hover:bg-accent'
              }`}
            >
              <span aria-hidden>🏠</span>
              {t('storage.drives.app_drive_title', 'App Drive')}
            </button>
            {/* BYOS drives */}
            {byosDrives.map((drive) => (
              <button
                key={drive.id}
                type="button"
                onClick={() => setActiveDrive(drive.id)}
                className={`w-full flex items-center gap-2 px-3 py-1.5 rounded-lg text-xs font-medium transition-colors select-none ${
                  state.activeDriveId === drive.id
                    ? 'bg-indigo-50 text-indigo-700'
                    : 'text-muted-foreground hover:bg-accent'
                }`}
                title={drive.nickname ?? drive.bucket_name ?? undefined}
              >
                <span aria-hidden>🪣</span>
                <span className="truncate">{drive.nickname ?? drive.bucket_name}</span>
              </button>
            ))}
          </div>
        )}

        {views.map((v) => {
          const active = state.view === v.key || (v.key === 'files' && state.view === 'search')
          return (
            <button
              key={v.key}
              type="button"
              onClick={() => setView(v.key)}
              className={`w-full flex items-center gap-2.5 px-3 py-2 rounded-lg text-sm font-medium transition-colors select-none ${
                active
                  ? 'bg-indigo-50 text-indigo-700'
                  : 'text-muted-foreground hover:bg-accent hover:text-foreground'
              }`}
            >
              <span className="text-base leading-none" aria-hidden>{v.icon}</span>
              {t(v.labelKey, v.labelFallback)}
            </button>
          )
        })}

        {state.view === 'files' && (
          <FolderTree tenantId={tenantId} hideFieldWork={hideFieldWork} />
        )}
      </nav>

      {/* Image preview panel */}
      {preview && preview.nodeType === 'file' && (
        <div className="mx-2 mb-3 rounded-xl border border-border bg-muted/30 overflow-hidden">
          <div className="relative w-full aspect-square bg-muted flex items-center justify-center">
            {isImage && isPreviewLoading ? (
              <div className="w-5 h-5 rounded-full border-2 border-indigo-300 border-t-indigo-600 animate-spin" />
            ) : isImage && signedUrl ? (
              <img
                src={signedUrl}
                alt={preview.name}
                className="w-full h-full object-contain"
              />
            ) : isPdf && isPreviewLoading ? (
              <div className="w-5 h-5 rounded-full border-2 border-indigo-300 border-t-indigo-600 animate-spin" />
            ) : isPdf && signedUrl ? (
              <iframe
                src={signedUrl}
                title={preview.name}
                className="w-full h-full border-0"
              />
            ) : isText && (isPreviewLoading || isTextPreviewLoading) ? (
              <div className="w-5 h-5 rounded-full border-2 border-indigo-300 border-t-indigo-600 animate-spin" />
            ) : isText && textPreview !== null ? (
              <pre className="w-full h-full overflow-auto p-2 text-[11px] leading-4 text-foreground whitespace-pre-wrap">
                {textPreview}
              </pre>
            ) : (
              <div className="flex flex-col items-center justify-center gap-2 px-3 text-center text-muted-foreground">
                <span className="text-4xl" aria-hidden>{getFileEmoji(preview.mimeType, 'file')}</span>
                <p className="text-xs">
                  {preview.mimeType ?? t('storage.explorer.meta_unknown_mime', 'Tipus desconegut')}
                </p>
              </div>
            )}
          </div>
          <div className="px-2 py-2 space-y-1.5 text-xs text-foreground">
            <p className="truncate font-medium" title={preview.name}>{preview.name}</p>
            <p>
              <span className="text-muted-foreground">{t('storage.explorer.meta_mime_type', 'MIME type')}:</span>{' '}
              {preview.mimeType ?? t('storage.explorer.meta_unknown_mime', 'Tipus desconegut')}
            </p>
            <p>
              <span className="text-muted-foreground">{t('storage.explorer.col_size', 'Mida')}:</span>{' '}
              {formatBytes(preview.sizeBytes)}
            </p>
            <p>
              <span className="text-muted-foreground">{t('storage.explorer.meta_added_on', 'Afegit el')}:</span>{' '}
              {preview.createdAt ? formatDateTime(preview.createdAt) : '—'}
            </p>
            <p>
              <span className="text-muted-foreground">{t('storage.explorer.meta_last_modified', 'Darrera modificació')}:</span>{' '}
              {preview.updatedAt ? formatDateTime(preview.updatedAt) : '—'}
            </p>

            {/* Download + Get URL actions */}
            {preview.storageKey && (
              <div className="flex gap-1.5 pt-1">
                <button
                  type="button"
                  onClick={handleDownload}
                  disabled={isDownloading}
                  className="flex-1 py-1 rounded-lg text-xs font-medium bg-muted text-foreground hover:bg-accent transition disabled:opacity-50"
                >
                  {isDownloading
                    ? '\u00B7\u00B7\u00B7'
                    : `⬇️ ${t('storage.share.download_btn', 'Descarregar')}`}
                </button>
                <button
                  type="button"
                  onClick={() => setShareModalOpen(true)}
                  className="flex-1 py-1 rounded-lg text-xs font-medium bg-indigo-50 text-indigo-700 border border-indigo-100 hover:bg-indigo-100 transition"
                >
                  🔗 {t('storage.share.get_url_btn', 'Obtenir URL')}
                </button>
              </div>
            )}
          </div>
        </div>
      )}

      {/* Quota at the bottom */}
      <div className="border-t border-border mt-auto">
        <QuotaWidget tenantId={tenantId} activeDriveId={state.activeDriveId} drives={byosDrives} />
      </div>

      {/* Get URL modal — rendered here so it floats above the whole page */}
      {shareModalOpen && preview && tenantId && (
        <GetUrlModal
          fileId={preview.id}
          fileName={preview.name}
          tenantId={tenantId}
          onClose={() => setShareModalOpen(false)}
        />
      )}
    </aside>
  )
}
