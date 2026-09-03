import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Copy, ExternalLink, Mail, Loader2, CheckCircle, AlertCircle } from 'lucide-react'
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { useToast } from '@/hooks/use-toast'
import { getDocumentUrl } from '../api/documentsService'
import type { ActiveDocument } from '../api/documentsService'

interface AuditExpeditionModalProps {
  open: boolean
  onClose: () => void
  documents: ActiveDocument[]
}

const DURATION_OPTIONS = [
  { value: 3600,        label: '1h' },
  { value: 8 * 3600,   label: '8h' },
  { value: 24 * 3600,  label: '24h' },
  { value: 7 * 24 * 3600, label: '7d' },
] as const

type UrlStatus = 'idle' | 'loading' | 'ok' | 'error'

interface DocUrlEntry {
  doc: ActiveDocument
  url: string | null
  status: UrlStatus
  error?: string
}

export function AuditExpeditionModal({ open, onClose, documents }: AuditExpeditionModalProps) {
  const { t } = useTranslation('documents')
  const { toast } = useToast()
  const [duration, setDuration] = useState<number>(24 * 3600)
  const [entries, setEntries] = useState<DocUrlEntry[]>([])
  const [generated, setGenerated] = useState(false)

  function reset() {
    setEntries([])
    setGenerated(false)
  }

  function handleClose() {
    reset()
    onClose()
  }

  async function handleGenerate() {
    const initial: DocUrlEntry[] = documents.map((doc) => ({
      doc,
      url: null,
      status: 'loading' as UrlStatus,
    }))
    setEntries(initial)
    setGenerated(true)

    // Parallel URL generation
    const updated = await Promise.all(
      initial.map(async (entry): Promise<DocUrlEntry> => {
        const { doc } = entry
        if (!doc.version_id) {
          return { ...entry, status: 'error', error: t('expedition.noVersion', 'Sense versió') }
        }
        try {
          if (doc.storage_type === 'external_link') {
            return { ...entry, url: doc.file_path_or_url ?? null, status: 'ok' }
          }
          const result = await getDocumentUrl(doc.version_id, duration)
          return { ...entry, url: result.url, status: 'ok' }
        } catch (err) {
          return {
            ...entry,
            status: 'error',
            error: err instanceof Error ? err.message : 'Error',
          }
        }
      })
    )
    setEntries(updated)
  }

  function buildPlainText(): string {
    return entries
      .filter((e) => e.status === 'ok' && e.url)
      .map((e) => `${e.doc.title}\n${e.url}`)
      .join('\n\n')
  }

  async function handleCopyAll() {
    const text = buildPlainText()
    await navigator.clipboard.writeText(text)
    toast({ title: t('expedition.copied', 'URLs copiades al porta-retalls') })
  }

  function handleEmail() {
    const subject = encodeURIComponent(t('expedition.emailSubject', 'Documents per auditoria'))
    const body = encodeURIComponent(buildPlainText())
    window.open(`mailto:?subject=${subject}&body=${body}`)
  }

  const doneCount = entries.filter((e) => e.status === 'ok').length
  const errorCount = entries.filter((e) => e.status === 'error').length
  const isLoading = entries.some((e) => e.status === 'loading')

  return (
    <Dialog open={open} onOpenChange={(v) => !v && handleClose()}>
      <DialogContent className="sm:max-w-2xl max-h-[85vh] flex flex-col">
        <DialogHeader>
          <DialogTitle>
            {t('expedition.title', 'Expedició d\'auditoria')}
          </DialogTitle>
        </DialogHeader>

        <div className="flex-1 overflow-y-auto space-y-4 pr-1">
          {/* Document list + duration selector */}
          {!generated && (
            <>
              <div className="space-y-1">
                <p className="text-sm font-medium">
                  {t('expedition.selectedDocs', '{{n}} document(s) seleccionat(s)', { n: documents.length })}
                </p>
                <div className="max-h-48 overflow-y-auto space-y-1 rounded border p-2">
                  {documents.map((doc) => (
                    <div key={doc.id} className="text-sm flex items-center gap-2">
                      <span className="truncate flex-1">{doc.title}</span>
                      {doc.expires_at && (
                        <span className="text-xs text-muted-foreground shrink-0">
                          {new Date(doc.expires_at).toLocaleDateString('ca-ES')}
                        </span>
                      )}
                    </div>
                  ))}
                </div>
              </div>

              <div>
                <label className="block text-sm font-medium mb-2">
                  {t('expedition.durationLabel', 'Validesa dels enllaços')}
                </label>
                <div className="flex gap-2 flex-wrap">
                  {DURATION_OPTIONS.map((opt) => (
                    <button
                      key={opt.value}
                      type="button"
                      onClick={() => setDuration(opt.value)}
                      className={`px-4 py-1.5 rounded-full text-sm font-medium transition-colors ${
                        duration === opt.value
                          ? 'bg-primary text-primary-foreground'
                          : 'bg-muted text-muted-foreground hover:bg-muted/70'
                      }`}
                    >
                      {opt.label}
                    </button>
                  ))}
                </div>
              </div>
            </>
          )}

          {/* Generated URLs */}
          {generated && (
            <div className="space-y-2">
              {entries.map((entry, idx) => (
                <div
                  key={entry.doc.id ?? idx}
                  className="rounded border px-3 py-2 text-sm space-y-0.5"
                >
                  <div className="flex items-center gap-2">
                    {entry.status === 'loading' && (
                      <Loader2 className="h-3.5 w-3.5 animate-spin text-muted-foreground shrink-0" />
                    )}
                    {entry.status === 'ok' && (
                      <CheckCircle className="h-3.5 w-3.5 text-green-500 shrink-0" />
                    )}
                    {entry.status === 'error' && (
                      <AlertCircle className="h-3.5 w-3.5 text-red-500 shrink-0" />
                    )}
                    <span className="font-medium truncate flex-1">{entry.doc.title}</span>
                    {entry.status === 'ok' && entry.url && (
                      <a
                        href={entry.url}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="shrink-0"
                        title={t('expedition.openLink', 'Obrir enllaç')}
                        aria-label={t('expedition.openLink', 'Obrir enllaç')}
                      >
                        <ExternalLink className="h-3.5 w-3.5 text-primary" />
                      </a>
                    )}
                  </div>
                  {entry.status === 'ok' && entry.url && (
                    <p className="text-xs text-muted-foreground break-all pl-5">
                      {entry.url.length > 80 ? `${entry.url.slice(0, 80)}…` : entry.url}
                    </p>
                  )}
                  {entry.status === 'error' && (
                    <p className="text-xs text-red-500 pl-5">{entry.error}</p>
                  )}
                </div>
              ))}
            </div>
          )}
        </div>

        {/* Footer actions */}
        <div className="border-t pt-3 flex items-center justify-between gap-2 flex-wrap">
          <div className="text-xs text-muted-foreground">
            {generated && !isLoading && (
              <span>
                {t('expedition.summary', '{{ok}} OK · {{err}} errors', {
                  ok: doneCount,
                  err: errorCount,
                })}
              </span>
            )}
          </div>
          <div className="flex gap-2">
            <Button variant="outline" size="sm" onClick={handleClose}>
              {t('common.close', 'Tancar')}
            </Button>
            {!generated && (
              <Button size="sm" onClick={handleGenerate} disabled={documents.length === 0}>
                {t('expedition.generate', 'Generar URLs')}
              </Button>
            )}
            {generated && !isLoading && doneCount > 0 && (
              <>
                <Button variant="outline" size="sm" onClick={handleCopyAll}>
                  <Copy className="h-4 w-4 mr-1" />
                  {t('expedition.copyAll', 'Copiar totes')}
                </Button>
                <Button variant="outline" size="sm" onClick={handleEmail}>
                  <Mail className="h-4 w-4 mr-1" />
                  {t('expedition.email', 'Enviar per email')}
                </Button>
              </>
            )}
            {generated && !isLoading && (
              <Button variant="ghost" size="sm" onClick={reset}>
                {t('expedition.reset', 'Tornar a generar')}
              </Button>
            )}
          </div>
        </div>
      </DialogContent>
    </Dialog>
  )
}
