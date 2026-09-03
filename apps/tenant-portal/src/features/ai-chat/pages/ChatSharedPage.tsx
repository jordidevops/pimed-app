import { useEffect, useState } from 'react'
import { useParams, Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { useQuery } from '@tanstack/react-query'
import { ArrowLeft, Eye, Loader2, Sparkles } from 'lucide-react'
import { fetchSharedConversation, type AiMessageRow } from '@/features/ai-chat/api/chatApi'
import { ChatThread } from '@/features/ai-chat/components/ChatThread'
import { Button } from '@/components/ui/button'
import { useTenant } from '@/contexts/TenantContext'

export function ChatSharedPage() {
  const { shareToken } = useParams<{ shareToken: string }>()
  const { t } = useTranslation('chat')
  const { activeTenant, selectedTenantId, tenantScopeReady } = useTenant()
  const [offset, setOffset] = useState(0)
  const [allMessages, setAllMessages] = useState<AiMessageRow[]>([])
  const tenantReady = tenantScopeReady && !!(selectedTenantId ?? activeTenant?.id)

  const { data, isLoading, error, isFetching } = useQuery({
    queryKey: ['ai_shared_conversation', shareToken, offset],
    enabled: !!shareToken && tenantReady,
    queryFn: () => fetchSharedConversation(shareToken!, { limit: 100, offset }),
    retry: false,
  })

  useEffect(() => {
    setOffset(0)
    setAllMessages([])
  }, [shareToken])

  useEffect(() => {
    if (!data) return
    setAllMessages((prev) => {
      const merged = [...prev, ...data.messages]
      const seen = new Set<string>()
      return merged.filter((m) => {
        if (!m?.id || seen.has(m.id)) return false
        seen.add(m.id)
        return true
      })
    })
  }, [data])

  const hasMore = data?.page?.has_more === true
  const nextOffset = data?.page?.next_offset ?? null
  return (
    <div className="flex h-[calc(100vh-4rem)] border-t flex-col">
      <header className="border-b px-4 py-3 flex items-center justify-between gap-3">
        <div className="flex items-center gap-2 min-w-0">
          <Sparkles className="h-5 w-5 text-indigo-600 shrink-0" />
          <div className="min-w-0">
            <h1 className="font-semibold truncate">
              {data?.conversation.title || t('title', 'Assistent IA')}
            </h1>
            {data?.conversation.owner_name && (
              <p className="text-xs text-muted-foreground truncate">
                {t('sharedBy', 'Compartida per {{name}}', { name: data.conversation.owner_name })}
              </p>
            )}
            {data?.conversation.share_expires_at && (
              <p className="text-[11px] text-muted-foreground truncate">
                {t('shareExpiresAt', 'Caduca: {{date}}', {
                  date: new Date(data.conversation.share_expires_at).toLocaleString(),
                })}
              </p>
            )}
          </div>
        </div>
        <Button asChild variant="outline" size="sm" className="shrink-0">
          <Link to="/ai/chat">
            <ArrowLeft className="h-4 w-4 mr-1.5" />
            {t('shareBackToChat', 'Tornar al xat')}
          </Link>
        </Button>
      </header>

      <div className="px-4 py-2 border-b bg-muted/30">
        <p className="text-xs text-muted-foreground inline-flex items-center gap-1.5">
          <Eye className="h-3.5 w-3.5" />
          {t('shareReadOnlyBanner', 'Vista només lectura — no pots enviar missatges ni modificar aquesta conversa.')}
        </p>
      </div>

      {isLoading && (
        <div className="p-6 text-muted-foreground text-sm">…</div>
      )}

      {!isLoading && !tenantReady && (
        <div className="p-6 text-muted-foreground text-sm">…</div>
      )}

      {error && (
        <div className="p-6 max-w-lg">
          <p className="text-sm text-destructive">
            {error instanceof Error
              ? error.message
              : t('shareNotFound', 'Conversa compartida no trobada o enllaç revocat.')}
          </p>
        </div>
      )}

      {data && (
        <>
          <ChatThread
            messages={allMessages}
            loading={false}
            thinking={false}
            streamingContent={null}
          />
          {hasMore && (
            <div className="px-4 pb-4">
              <div className="max-w-3xl mx-auto">
                <Button
                  type="button"
                  variant="outline"
                  size="sm"
                  disabled={isFetching || nextOffset == null}
                  onClick={() => {
                    if (nextOffset != null) setOffset(nextOffset)
                  }}
                >
                  {isFetching ? <Loader2 className="h-4 w-4 mr-1.5 animate-spin" /> : null}
                  {t('shareLoadMore', 'Carregar més missatges')}
                </Button>
              </div>
            </div>
          )}
        </>
      )}
    </div>
  )
}
