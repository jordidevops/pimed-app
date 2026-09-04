import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Bell } from 'lucide-react'
import { Popover, PopoverContent, PopoverTrigger } from '@/components/ui/popover'
import { Button } from '@/components/ui/button'
import { cn } from '@/lib/utils'
import { useAuth } from '@/contexts/AuthContext'
import { useNotificationsRealtime } from '../api/useNotificationsRealtime'
import { invalidateEntityTimelineCaches } from '@/features/entity-timeline/api/invalidateEntityTimelineCaches'
import { parseTimelineDeepLink } from '@/features/entity-timeline/utils/timelineDeepLink'
import {
  countUnreadNotifications,
  formatNotificationBody,
  formatNotificationTitle,
  listMyNotifications,
  markAllNotificationsRead,
  markNotificationRead,
} from '../api/inboxService'

interface NotificationBellProps {
  compact?: boolean
  /** Classes de hover/estat idle del sidebar (mateix estil que els NavLink). */
  itemClassName?: string
}

export function NotificationBell({ compact = false, itemClassName }: NotificationBellProps) {
  const { t } = useTranslation('common')
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const { user } = useAuth()
  const [open, setOpen] = useState(false)

  useNotificationsRealtime(user?.id)

  const { data: unreadCount = 0 } = useQuery({
    queryKey: ['notifications-unread-count'],
    queryFn: countUnreadNotifications,
    staleTime: 0,
    refetchOnWindowFocus: true,
    refetchInterval: 30_000,
  })

  useEffect(() => {
    if (open) {
      void queryClient.invalidateQueries({ queryKey: ['notifications-unread-count'] })
    }
  }, [open, queryClient])

  const { data: notifications = [], isLoading } = useQuery({
    queryKey: ['notifications-inbox'],
    queryFn: () => listMyNotifications(25),
    enabled: open,
  })

  const markReadMut = useMutation({
    mutationFn: markNotificationRead,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['notifications-inbox'] })
      queryClient.invalidateQueries({ queryKey: ['notifications-unread-count'] })
    },
  })

  const markAllMut = useMutation({
    mutationFn: markAllNotificationsRead,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['notifications-inbox'] })
      queryClient.invalidateQueries({ queryKey: ['notifications-unread-count'] })
    },
  })

  async function handleNotificationClick(id: string, deepLink: string | null, read: boolean) {
    if (!read) {
      await markReadMut.mutateAsync(id)
    }
    setOpen(false)
    if (deepLink) {
      const parsed = parseTimelineDeepLink(deepLink)
      if (parsed) {
        await invalidateEntityTimelineCaches(queryClient, parsed.entityType, parsed.entityId)
      }
      navigate(deepLink)
    }
  }

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <button
          type="button"
          className={
            compact
              ? 'relative tp-nav-item tp-nav-item-compact'
              : cn('relative tp-nav-item', itemClassName)
          }
          aria-label={t('notifications.bell_label', 'Notificacions')}
        >
          <Bell className={compact ? 'h-5 w-5' : 'h-5 w-5 shrink-0'} />
          {!compact && <span>{t('notifications.bell_title', 'Notificacions')}</span>}
          {unreadCount > 0 && (
            <span
              className={
                compact
                  ? 'absolute -right-0.5 -top-0.5 inline-flex h-4 min-w-4 items-center justify-center rounded-full bg-primary px-1 text-[9px] font-semibold text-primary-foreground'
                  : 'ml-auto inline-flex h-5 min-w-5 items-center justify-center rounded-full bg-primary px-1.5 text-[10px] font-semibold text-primary-foreground'
              }
            >
              {unreadCount > 99 ? '99+' : unreadCount}
            </span>
          )}
        </button>
      </PopoverTrigger>
      <PopoverContent className="w-80 p-0" align="start" side="top">
        <div className="flex items-center justify-between border-b px-3 py-2">
          <p className="text-sm font-semibold">{t('notifications.inbox_title', 'Safata')}</p>
          {unreadCount > 0 && (
            <Button
              type="button"
              variant="ghost"
              size="sm"
              className="h-7 text-xs"
              disabled={markAllMut.isPending}
              onClick={() => markAllMut.mutate()}
            >
              {t('notifications.mark_all_read', 'Marcar tot llegit')}
            </Button>
          )}
        </div>

        <div className="max-h-80 overflow-y-auto">
          {isLoading && (
            <p className="px-3 py-4 text-xs text-muted-foreground">
              {t('notifications.loading', 'Carregant...')}
            </p>
          )}

          {!isLoading && notifications.length === 0 && (
            <p className="px-3 py-4 text-xs text-muted-foreground">
              {t('notifications.empty', 'Cap notificació')}
            </p>
          )}

          <ul>
            {notifications.map((n) => {
              const isUnread = !n.read_at
              return (
                <li key={n.id}>
                  <button
                    type="button"
                    className={`w-full text-left px-3 py-2.5 border-b border-border/60 hover:bg-accent/50 transition-colors ${
                      isUnread ? 'bg-primary/5' : ''
                    }`}
                    onClick={() => void handleNotificationClick(n.id, n.deep_link, !isUnread)}
                  >
                    <p className="text-xs font-medium text-foreground">
                      {formatNotificationTitle(n)}
                    </p>
                    {formatNotificationBody(n) && (
                      <p className="text-xs text-muted-foreground mt-0.5 line-clamp-2">
                        {formatNotificationBody(n)}
                      </p>
                    )}
                    <p className="text-[10px] text-muted-foreground mt-1">
                      {new Date(n.created_at).toLocaleString('ca-ES')}
                    </p>
                  </button>
                </li>
              )
            })}
          </ul>
        </div>
      </PopoverContent>
    </Popover>
  )
}
