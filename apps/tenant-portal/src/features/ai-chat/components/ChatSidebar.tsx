import type { AiConversationRow } from '../api/chatApi'
import { MessageSquarePlus, Trash2 } from 'lucide-react'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { cn } from '@/lib/utils'

type ChatSidebarProps = {
  conversations: AiConversationRow[]
  activeConversationId: string | null
  loading: boolean
  onSelect: (id: string | null) => void
  onDelete: (id: string) => void
}

export function ChatSidebar({
  conversations,
  activeConversationId,
  loading,
  onSelect,
  onDelete,
}: ChatSidebarProps) {
  const { t } = useTranslation('chat')

  return (
    <aside className="w-64 border-r flex flex-col bg-muted/30">
      <div className="p-3 border-b">
        <Button
          variant="outline"
          className="w-full justify-start gap-2"
          onClick={() => onSelect(null)}
        >
          <MessageSquarePlus className="h-4 w-4" />
          {t('newChat', 'Nou xat')}
        </Button>
      </div>
      <div className="flex-1 min-h-0 overflow-y-auto">
        <div className="p-2 space-y-1">
          {loading && <p className="text-xs text-muted-foreground p-2">…</p>}
          {!loading && conversations.length === 0 && (
            <p className="text-xs text-muted-foreground p-2">
              {t('emptyConversations', 'Encara no tens converses')}
            </p>
          )}
          {conversations.map((c) => (
            <div key={c.id} className="flex items-center gap-1">
              <button
                type="button"
                onClick={() => onSelect(c.id)}
                className={cn(
                  'flex-1 text-left text-sm px-2 py-2 rounded-lg truncate hover:bg-accent',
                  activeConversationId === c.id && 'bg-accent font-medium',
                )}
              >
                {c.title || t('newChat', 'Nou xat')}
              </button>
              <Button
                variant="ghost"
                size="icon"
                className="h-8 w-8 shrink-0"
                onClick={() => onDelete(c.id)}
                aria-label={t('delete', 'Eliminar conversa')}
              >
                <Trash2 className="h-3.5 w-3.5" />
              </Button>
            </div>
          ))}
        </div>
      </div>
    </aside>
  )
}
