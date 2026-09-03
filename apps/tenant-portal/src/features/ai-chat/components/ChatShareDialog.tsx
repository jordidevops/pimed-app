import { useState } from 'react'
import { Copy, Check, Link2, Link2Off } from 'lucide-react'
import { useTranslation } from 'react-i18next'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { useToast } from '@/hooks/use-toast'
import {
  disableConversationShare,
  enableConversationShare,
  fetchConversationShareStatus,
} from '@/features/ai-chat/api/chatApi'

type ChatShareDialogProps = {
  open: boolean
  onOpenChange: (open: boolean) => void
  conversationId: string
  conversationTitle?: string | null
}

function buildShareUrl(shareToken: string): string {
  return `${window.location.origin}/ai/chat/s/${shareToken}`
}

export function ChatShareDialog({
  open,
  onOpenChange,
  conversationId,
  conversationTitle,
}: ChatShareDialogProps) {
  const { t } = useTranslation('chat')
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const [copied, setCopied] = useState(false)

  const { data: status, isLoading } = useQuery({
    queryKey: ['ai_conversation_share', conversationId],
    queryFn: () => fetchConversationShareStatus(conversationId),
    enabled: open && !!conversationId,
  })

  const enableMutation = useMutation({
    mutationFn: () => enableConversationShare(conversationId, 7 * 24 * 3600),
    onSuccess: async (result) => {
      await queryClient.invalidateQueries({ queryKey: ['ai_conversation_share', conversationId] })
      if (result.share_token) {
        await copyShareUrl(result.share_token)
      }
      toast({ description: t('shareEnabled', 'Enllaç de compartició activat') })
    },
    onError: (err) => {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : t('shareEnableError', 'No s\'ha pogut activar l\'enllaç'),
      })
    },
  })

  const disableMutation = useMutation({
    mutationFn: () => disableConversationShare(conversationId),
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ['ai_conversation_share', conversationId] })
      toast({ description: t('shareDisabled', 'Enllaç de compartició revocat') })
    },
    onError: (err) => {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : t('shareDisableError', 'No s\'ha pogut revocar l\'enllaç'),
      })
    },
  })

  async function copyShareUrl(token: string) {
    const url = buildShareUrl(token)
    await navigator.clipboard.writeText(url)
    setCopied(true)
    window.setTimeout(() => setCopied(false), 2000)
  }

  const shareToken = status?.share_token ?? null
  const shareExpiresAt = status?.share_expires_at ?? null
  const enabled = status?.enabled === true && !!shareToken
  const busy = enableMutation.isPending || disableMutation.isPending

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-lg">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            <Link2 className="h-4 w-4" />
            {t('shareTitle', 'Compartir conversa')}
          </DialogTitle>
          <DialogDescription>
            {conversationTitle
              ? t('shareDescriptionNamed', 'Comparteix «{{title}}» en mode només lectura amb altres membres del tenant.', { title: conversationTitle })
              : t('shareDescription', 'Comparteix aquesta conversa en mode només lectura amb altres membres del tenant.')}
          </DialogDescription>
        </DialogHeader>

        {isLoading ? (
          <p className="text-sm text-muted-foreground">…</p>
        ) : enabled && shareToken ? (
          <div className="space-y-3">
            <div className="rounded-md border bg-muted/40 p-3">
              <p className="text-xs text-muted-foreground mb-1">
                {t('shareLinkLabel', 'Enllaç (requereix iniciar sessió al tenant)')}
              </p>
              <p className="text-xs break-all font-mono">{buildShareUrl(shareToken)}</p>
              {shareExpiresAt && (
                <p className="text-[11px] text-muted-foreground mt-1.5">
                  {t('shareExpiresAt', 'Caduca: {{date}}', {
                    date: new Date(shareExpiresAt).toLocaleString(),
                  })}
                </p>
              )}
            </div>
            <div className="flex flex-wrap gap-2">
              <Button
                type="button"
                variant="outline"
                size="sm"
                disabled={busy}
                onClick={() => void copyShareUrl(shareToken)}
              >
                {copied ? <Check className="h-4 w-4 mr-1.5" /> : <Copy className="h-4 w-4 mr-1.5" />}
                {copied ? t('shareCopied', 'Copiat') : t('shareCopy', 'Copiar enllaç')}
              </Button>
              <Button
                type="button"
                variant="destructive"
                size="sm"
                disabled={busy}
                onClick={() => disableMutation.mutate()}
              >
                <Link2Off className="h-4 w-4 mr-1.5" />
                {t('shareRevoke', 'Revocar enllaç')}
              </Button>
            </div>
          </div>
        ) : (
          <div className="space-y-3">
            <p className="text-sm text-muted-foreground">
              {t('shareHint', 'Els membres del tenant amb accés al xat podran veure la conversa però no enviar missatges ni aplicar propostes.')}
            </p>
            <Button
              type="button"
              disabled={busy}
              onClick={() => enableMutation.mutate()}
            >
              <Link2 className="h-4 w-4 mr-1.5" />
              {t('shareEnable', 'Generar enllaç de compartició')}
            </Button>
          </div>
        )}
      </DialogContent>
    </Dialog>
  )
}
