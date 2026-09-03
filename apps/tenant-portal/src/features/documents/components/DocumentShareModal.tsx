import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { Copy, Check, ExternalLink, Trash2, Link } from 'lucide-react'
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { useToast } from '@/hooks/use-toast'
import {
  getDocumentShareLinks,
  createDocumentShareLink,
  revokeDocumentShareLink,
} from '../api/documentsService'
import type { ActiveDocument } from '../api/documentsService'

interface DocumentShareModalProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  document: ActiveDocument
  tenantId: string
}

const EXPIRY_OPTIONS = [
  { value: '3600',   label: 'shareLinks.expiry1h'  },
  { value: '86400',  label: 'shareLinks.expiry24h', default: true },
  { value: '604800', label: 'shareLinks.expiry7d'  },
  { value: '2592000', label: 'shareLinks.expiry30d' },
] as const

function formatDate(iso: string): string {
  return new Date(iso).toLocaleString('ca-ES', {
    day: '2-digit', month: '2-digit', year: 'numeric',
    hour: '2-digit', minute: '2-digit',
  })
}

export function DocumentShareModal({ open, onOpenChange, document: doc, tenantId }: DocumentShareModalProps) {
  const { t } = useTranslation('documents')
  const { toast } = useToast()
  const queryClient = useQueryClient()

  const [selectedExpiry, setSelectedExpiry] = useState('86400')
  const [copiedId, setCopiedId] = useState<string | null>(null)

  // Fetch existing share links for this document
  const { data: links = [], isLoading } = useQuery({
    queryKey: ['document-share-links', doc.id],
    queryFn: () => getDocumentShareLinks(doc.id!),
    enabled: open && !!doc.id,
  })

  const activeLinks = links.filter((l) => l.is_active)

  // The latest version_id — needed for creating the share link
  const versionId = (doc as any).version_id as string | undefined

  const canShare = doc.storage_type === 'native' && !!versionId

  const createMutation = useMutation({
    mutationFn: () =>
      createDocumentShareLink({
        tenantId,
        documentId: doc.id!,
        documentVersionId: versionId!,
        expirySeconds: parseInt(selectedExpiry),
      }),
    onSuccess: (result) => {
      queryClient.invalidateQueries({ queryKey: ['document-share-links', doc.id] })
      queryClient.invalidateQueries({ queryKey: ['document-share-link-active-count', doc.id] })
      queryClient.invalidateQueries({ queryKey: ['document-share-link-counts'] })
      toast({ description: t('shareLinks.created', 'Link de compartició creat') })
      // Copy to clipboard immediately
      copyToClipboard(result.id, result.share_url)
    },
    onError: (err) => {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : t('shareLinks.createError', 'Error en crear el link'),
      })
    },
  })

  const revokeMutation = useMutation({
    mutationFn: (linkId: string) => revokeDocumentShareLink(linkId),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['document-share-links', doc.id] })
      queryClient.invalidateQueries({ queryKey: ['document-share-link-active-count', doc.id] })
      queryClient.invalidateQueries({ queryKey: ['document-share-link-counts'] })
      toast({ description: t('shareLinks.revoked', 'Link revocat') })
    },
    onError: (err) => {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : t('shareLinks.revokeError', 'Error en revocar el link'),
      })
    },
  })

  function buildShareUrl(token: string): string {
    return `${import.meta.env.VITE_SUPABASE_URL}/functions/v1/resolve-document-share?token=${token}`
  }

  function copyToClipboard(linkId: string, url: string) {
    navigator.clipboard.writeText(url).then(() => {
      setCopiedId(linkId)
      setTimeout(() => setCopiedId(null), 2000)
    })
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-lg">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            <Link className="h-4 w-4" />
            {t('shareLinks.modalTitle', 'Links de compartició')}
          </DialogTitle>
          <DialogDescription>
            <span className="font-medium text-foreground">{doc.title}</span>
            {' — '}
            {t('shareLinks.modalDescription', 'Genera un link temporal per compartir aquest document amb persones externes sense necessitat d\'autenticació.')}
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-4 pt-2">
          {/* ── Only native storage can be shared ── */}
          {!canShare && (
            <p className="text-sm text-muted-foreground bg-muted rounded-lg px-4 py-3">
              {t('shareLinks.onlyNative', 'Només es poden compartir documents emmagatzemats al sistema (no links externs).')}
            </p>
          )}

          {/* ── Create new link ── */}
          {canShare && (
            <div className="flex items-center gap-2">
              <select
                title={t('shareLinks.expirySelect', 'Selecciona la durada del link')} 
                value={selectedExpiry}
                onChange={(e) => setSelectedExpiry(e.target.value)}
                className="flex-1 h-9 rounded-md border bg-background px-3 text-sm focus:outline-none focus:ring-2 focus:ring-ring"
              >
                {EXPIRY_OPTIONS.map((opt) => (
                  <option key={opt.value} value={opt.value}>
                    {t(opt.label as any, opt.value)}
                  </option>
                ))}
              </select>
              <Button
                onClick={() => createMutation.mutate()}
                disabled={createMutation.isPending}
                size="sm"
              >
                {createMutation.isPending
                  ? t('shareLinks.creating', 'Generant...')
                  : t('shareLinks.createButton', 'Generar link')}
              </Button>
            </div>
          )}

          {/* ── Active links list ── */}
          {canShare && (
            <div className="space-y-2">
              <p className="text-xs font-semibold uppercase tracking-widest text-muted-foreground">
                {t('shareLinks.activeLinks', 'Links actius')}
              </p>

              {isLoading && (
                <div className="h-8 bg-muted rounded animate-pulse" />
              )}

              {!isLoading && activeLinks.length === 0 && (
                <p className="text-sm text-muted-foreground">
                  {t('shareLinks.noActiveLinks', 'Cap link actiu')}
                </p>
              )}

              {activeLinks.map((link) => {
                const url = buildShareUrl(link.token)
                const isCopied = copiedId === link.id

                return (
                  <div key={link.id} className="rounded-lg border bg-muted/30 text-sm p-3 space-y-1.5">
                    <p className="text-xs text-muted-foreground font-mono break-all leading-relaxed">{url}</p>
                    <div className="flex items-center justify-between gap-2">
                      <p className="text-[11px] text-muted-foreground">
                        {t('shareLinks.expiresAt', 'Caduca {{date}}', { date: formatDate(link.expires_at) })}
                        {link.access_count > 0 && (
                          <> · {t('shareLinks.accessCount', '{{count}} accés(os)', { count: link.access_count })}</>
                        )}
                      </p>
                    <div className="flex items-center gap-1 shrink-0">
                      <Button
                        variant="ghost"
                        size="icon"
                        className="h-7 w-7"
                        onClick={() => window.open(url, '_blank')}
                        title="Obrir link"
                      >
                        <ExternalLink className="h-3.5 w-3.5" />
                      </Button>
                      <Button
                        variant="ghost"
                        size="icon"
                        className="h-7 w-7"
                        onClick={() => copyToClipboard(link.id, url)}
                        title={t('shareLinks.copyButton', 'Copiar')}
                      >
                        {isCopied
                          ? <Check className="h-3.5 w-3.5 text-green-500" />
                          : <Copy className="h-3.5 w-3.5" />
                        }
                      </Button>
                      <Button
                        variant="ghost"
                        size="icon"
                        className="h-7 w-7 text-destructive hover:text-destructive"
                        disabled={revokeMutation.isPending}
                        onClick={() => {
                          if (confirm(t('shareLinks.revokeConfirm', 'Vols revocar aquest link? No es podrà tornar a usar.'))) {
                            revokeMutation.mutate(link.id)
                          }
                        }}
                        title={t('shareLinks.revokeButton', 'Revocar')}
                      >
                        <Trash2 className="h-3.5 w-3.5" />
                      </Button>
                    </div>
                    </div>
                  </div>
                )
              })}
            </div>
          )}
        </div>
      </DialogContent>
    </Dialog>
  )
}
