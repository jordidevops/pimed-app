import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useExplorer } from '../contexts/ExplorerContext'
import { formatBytes, formatDateTime } from '../utils/fileUtils'
import { getFileUrl } from '../api/storageService'

export function FilePreviewModal({ tenantId }: { tenantId: string }) {
  const { t } = useTranslation('storage')
  const { state, closePreview } = useExplorer()

  const nodeId = state.previewNodeId
  const node = state.sidebarPreview && state.sidebarPreview.id === nodeId ? state.sidebarPreview : null
  const [signedUrl, setSignedUrl] = useState<string | null>(null)
  const [isLoadingPreview, setIsLoadingPreview] = useState(false)
  const [textPreview, setTextPreview] = useState<string | null>(null)
  const [isLoadingText, setIsLoadingText] = useState(false)
  const [isDownloading, setIsDownloading] = useState(false)

  const mime = node?.mimeType ?? ''
  const isImage = mime.startsWith('image/')
  const isPdf = mime === 'application/pdf'
  const isText = mime.startsWith('text/')
  const needsSignedUrl = isImage || isPdf || isText

  useEffect(() => {
    if (!node?.id || !tenantId || !needsSignedUrl) {
      setSignedUrl(null)
      setIsLoadingPreview(false)
      return
    }

    let cancelled = false
    setIsLoadingPreview(true)

    // Resolve signed URL through backend so it works for both Supabase and BYOS.
    getFileUrl(node.id, 120, tenantId, false)
      .then(({ url }) => {
        if (cancelled) return
        setSignedUrl(url ?? null)
        setIsLoadingPreview(false)
      })
      .catch(() => {
        if (cancelled) return
        setSignedUrl(null)
        setIsLoadingPreview(false)
      })

    return () => {
      cancelled = true
    }
  }, [node?.id, tenantId, needsSignedUrl])

  useEffect(() => {
    if (!isText || !signedUrl) {
      setTextPreview(null)
      setIsLoadingText(false)
      return
    }

    let cancelled = false
    setIsLoadingText(true)

    fetch(signedUrl)
      .then((res) => (res.ok ? res.text() : Promise.reject(new Error('text_fetch_failed'))))
      .then((content) => {
        if (cancelled) return
        // Keep sidebar and modal lightweight with bounded text preview.
        setTextPreview(content.slice(0, 20000))
        setIsLoadingText(false)
      })
      .catch(() => {
        if (cancelled) return
        setTextPreview(null)
        setIsLoadingText(false)
      })

    return () => {
      cancelled = true
    }
  }, [isText, signedUrl])

  // Close on Escape
  useEffect(() => {
    if (!nodeId) return
    const handler = (e: KeyboardEvent) => {
      if (e.key === 'Escape') closePreview()
    }
    window.addEventListener('keydown', handler)
    return () => window.removeEventListener('keydown', handler)
  }, [nodeId, closePreview])

  if (!nodeId || !node) return null

  async function handleDownload() {
    if (!node?.id || !tenantId) return
    setIsDownloading(true)
    try {
      const { url } = await getFileUrl(node.id, 300, tenantId, true)
      window.open(url, '_blank', 'noopener,noreferrer')
    } catch {
      // Silent fail
    } finally {
      setIsDownloading(false)
    }
  }

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 backdrop-blur-sm"
      onClick={closePreview}
    >
      <div
        className="bg-card rounded-2xl shadow-2xl w-full max-w-3xl max-h-[85vh] flex flex-col overflow-hidden mx-4"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Header */}
        <div className="flex items-center justify-between px-5 py-3 border-b border-border">
          <div className="min-w-0">
            <h3 className="text-sm font-semibold text-foreground truncate">{node.name}</h3>
            <p className="text-xs text-muted-foreground mt-0.5">
              {formatBytes(node.sizeBytes)} · {node.updatedAt ? formatDateTime(node.updatedAt) : '—'}
            </p>
          </div>
          <div className="flex items-center gap-2 ml-3 shrink-0">
            {/* Download button — always available when storageKey exists */}
            {node.storageKey && (
              <button
                type="button"
                onClick={handleDownload}
                disabled={isDownloading}
                className="flex items-center gap-1 px-3 py-1 rounded-lg text-xs font-medium bg-muted text-foreground hover:bg-accent transition disabled:opacity-50"
                aria-label={t('storage.share.download_btn', 'Descarregar')}
              >
                ⬇️ {isDownloading ? '\u00B7\u00B7\u00B7' : t('storage.share.download_btn', 'Descarregar')}
              </button>
            )}
            <button
              type="button"
              onClick={closePreview}
              className="p-1 rounded-lg text-muted-foreground hover:bg-accent hover:text-accent-foreground transition"
              aria-label={t('storage.explorer.preview_close', 'Tanca la previsualització')}
            >
              <svg className="h-5 w-5" viewBox="0 0 20 20" fill="currentColor" aria-hidden>
                <path d="M6.28 5.22a.75.75 0 0 0-1.06 1.06L8.94 10l-3.72 3.72a.75.75 0 1 0 1.06 1.06L10 11.06l3.72 3.72a.75.75 0 1 0 1.06-1.06L11.06 10l3.72-3.72a.75.75 0 0 0-1.06-1.06L10 8.94 6.28 5.22Z" />
              </svg>
            </button>
          </div>
        </div>

        {/* Content */}
        <div className="flex-1 overflow-auto flex items-center justify-center p-6 bg-muted/30">
          {/* Image */}
          {isImage && (
            isLoadingPreview ? (
              <div className="w-8 h-8 rounded-full border-2 border-indigo-300 border-t-indigo-600 animate-spin" />
            ) : signedUrl ? (
              <img
                src={signedUrl}
                alt={node.name}
                className="max-w-full max-h-full object-contain rounded-lg"
              />
            ) : (
              <div className="flex flex-col items-center justify-center gap-3 text-muted-foreground">
                <span className="text-5xl">🖼️</span>
                <p className="text-sm">{t('storage.explorer.preview_unavailable', 'Vista prèvia no disponible')}</p>
              </div>
            )
          )}

          {/* PDF */}
          {isPdf && (
            isLoadingPreview ? (
              <div className="w-8 h-8 rounded-full border-2 border-indigo-300 border-t-indigo-600 animate-spin" />
            ) : signedUrl ? (
              <iframe
                src={signedUrl}
                title={node.name}
                className="w-full h-full min-h-[520px] rounded-lg bg-card"
              />
            ) : (
              <div className="w-full h-full min-h-[400px] flex flex-col items-center justify-center gap-3 text-muted-foreground">
                <span className="text-5xl">📕</span>
                <p className="text-sm">{t('storage.explorer.preview_unavailable', 'Vista prèvia no disponible')}</p>
              </div>
            )
          )}

          {/* Text */}
          {isText && (
            isLoadingPreview || isLoadingText ? (
              <div className="w-full h-full min-h-[260px] flex flex-col items-center justify-center gap-3 text-muted-foreground">
                <div className="w-8 h-8 rounded-full border-2 border-primary/30 border-t-primary animate-spin" />
                <p className="text-sm">{t('storage.explorer.preview_text_loading', 'Carregant text...')}</p>
              </div>
            ) : textPreview !== null ? (
              <pre className="w-full h-full min-h-[260px] overflow-auto rounded-lg border border-border bg-card p-4 text-xs leading-5 text-foreground whitespace-pre-wrap">
                {textPreview}
              </pre>
            ) : (
              <div className="w-full h-full min-h-[200px] flex flex-col items-center justify-center gap-3 text-muted-foreground">
                <span className="text-5xl">📄</span>
                <p className="text-sm">{t('storage.explorer.preview_unavailable', 'Vista prèvia no disponible')}</p>
              </div>
            )
          )}

          {/* Unsupported type */}
          {!isImage && !isPdf && !isText && (
            <div className="flex flex-col items-center justify-center gap-3 text-muted-foreground">
              <span className="text-5xl">📦</span>
              <p className="text-sm font-medium">{t('storage.explorer.preview_unsupported', 'No es pot previsualitzar aquest tipus de fitxer.')}</p>
              <p className="text-xs">{mime}</p>
              {node.storageKey && (
                <button
                  type="button"
                  onClick={handleDownload}
                  disabled={isDownloading}
                  className="mt-1 px-4 py-2 rounded-xl text-sm font-semibold bg-indigo-600 text-white hover:bg-indigo-700 transition disabled:opacity-50"
                >
                  ⬇️ {isDownloading
                    ? t('storage.share.downloading', 'Descarregant...')
                    : t('storage.share.download_btn', 'Descarregar fitxer')}
                </button>
              )}
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
