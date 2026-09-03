import { useState } from 'react'
import { CheckCircle2, ExternalLink, FileText, Loader2, XCircle } from 'lucide-react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { useTenant } from '@/contexts/TenantContext'
import { useToast } from '@/hooks/use-toast'
import { useDocument } from '@/features/documents/api/useDocument'
import { getDocumentUrl } from '@/features/documents/api/documentsService'
import { supabase } from '@/lib/supabase'
import type { DocumentResultUiBlock } from '@/features/ai-chat/schemas/chartBlock'

type Props = {
  block: DocumentResultUiBlock
}

export function ChatDocumentResultBlock({ block }: Props) {
  const { t } = useTranslation('chat')
  const { toast } = useToast()
  const { activeTenant } = useTenant()
  const [opening, setOpening] = useState(false)
  const { data: doc, isLoading: docLoading } = useDocument(block.documentId, activeTenant?.id)

  async function handleOpenFile() {
    if (!block.documentId) return
    setOpening(true)
    try {
      let url: string | null = null

      if (doc?.version_id) {
        const result = await getDocumentUrl(doc.version_id)
        url = result.url
      } else if (doc?.file_path_or_url) {
        if (doc.storage_type === 'external_link') {
          url = doc.file_path_or_url
        } else {
          const { data, error } = await supabase.storage
            .from('documents')
            .createSignedUrl(doc.file_path_or_url, 3600)
          if (error || !data?.signedUrl) {
            throw new Error(error?.message ?? t('documentResultOpenError', 'No s\'ha pogut obrir el document'))
          }
          url = data.signedUrl
        }
      }

      if (!url) {
        throw new Error(t('documentResultOpenError', 'No s\'ha pogut obrir el document'))
      }

      window.open(url, '_blank', 'noopener,noreferrer')
    } catch (err) {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : String(err),
      })
    } finally {
      setOpening(false)
    }
  }

  if (!block.success) {
    return (
      <div className="rounded-xl border border-destructive/30 bg-destructive/5 p-4 space-y-2 max-w-md">
        <div className="flex items-start gap-2">
          <XCircle className="h-5 w-5 text-destructive shrink-0 mt-0.5" />
          <div>
            <p className="text-sm font-medium text-destructive">
              {t('documentResultFailed', 'No s\'ha pogut generar el document')}
            </p>
            {block.error && (
              <p className="text-xs text-destructive/80 mt-1">{block.error}</p>
            )}
          </div>
        </div>
      </div>
    )
  }

  const openLabel = block.outputFormat === 'pdf'
    ? t('documentResultOpenPdf', 'Obrir PDF')
    : t('documentResultOpen', 'Obrir document')

  return (
    <div className="rounded-xl border border-emerald-200 bg-emerald-50/50 p-4 space-y-3 max-w-md">
      <div className="flex items-start gap-2">
        <CheckCircle2 className="h-5 w-5 text-emerald-600 shrink-0 mt-0.5" />
        <div className="space-y-1 min-w-0">
          <p className="text-sm font-medium text-emerald-950">
            {t('documentResultSuccess', 'Document generat correctament')}
          </p>
          {block.documentTitle && (
            <p className="text-xs text-emerald-900/80 flex items-center gap-1">
              <FileText className="h-3.5 w-3.5 shrink-0" />
              {block.documentTitle}
              {block.outputFormat ? ` · ${block.outputFormat.toUpperCase()}` : ''}
            </p>
          )}
        </div>
      </div>
      {block.documentId && (
        <div className="flex flex-wrap gap-2 justify-end">
          <Button
            type="button"
            variant="outline"
            size="sm"
            disabled={opening || docLoading}
            onClick={() => void handleOpenFile()}
          >
            {opening || docLoading ? (
              <Loader2 className="h-4 w-4 mr-1 animate-spin" />
            ) : (
              <ExternalLink className="h-4 w-4 mr-1" />
            )}
            {openLabel}
          </Button>
          <Button asChild variant="ghost" size="sm">
            <Link to={`/documents/${block.documentId}`}>
              {t('documentResultGoToPage', 'Anar a la pàgina del document')}
            </Link>
          </Button>
        </div>
      )}
    </div>
  )
}
