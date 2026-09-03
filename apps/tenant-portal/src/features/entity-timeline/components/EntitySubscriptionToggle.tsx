import { useTranslation } from 'react-i18next'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Bell, BellOff } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { useToast } from '@/hooks/use-toast'
import {
  getEntitySubscriptionStatus,
  setEntitySubscription,
  type EntityTimelineType,
} from '../api/timelineService'

interface EntitySubscriptionToggleProps {
  entityType: EntityTimelineType
  entityId: string
}

export function EntitySubscriptionToggle({
  entityType,
  entityId,
}: EntitySubscriptionToggleProps) {
  const { t } = useTranslation('activity')
  const { toast } = useToast()
  const queryClient = useQueryClient()

  const queryKey = ['entity-subscription', entityType, entityId]

  const { data: subscribed = false, isLoading } = useQuery({
    queryKey,
    queryFn: () => getEntitySubscriptionStatus(entityType, entityId),
    staleTime: 30_000,
  })

  const toggleMut = useMutation({
    mutationFn: (next: boolean) => setEntitySubscription(entityType, entityId, next),
    onSuccess: async (next) => {
      queryClient.setQueryData(queryKey, next)
      toast({
        description: next
          ? t('subscriptions.enabled', 'Segueixes l\'activitat d\'aquesta entitat.')
          : t('subscriptions.disabled', 'Has deixat de seguir l\'activitat.'),
      })
    },
    onError: () => {
      toast({
        variant: 'destructive',
        description: t('subscriptions.error', 'Error en actualitzar la subscripció.'),
      })
    },
  })

  return (
    <Button
      type="button"
      variant={subscribed ? 'secondary' : 'outline'}
      size="sm"
      className="h-8 gap-1.5 text-xs"
      disabled={isLoading || toggleMut.isPending}
      title={
        subscribed
          ? t('subscriptions.unfollow_title', 'Deixar de seguir activitat')
          : t('subscriptions.follow_title', 'Seguir activitat')
      }
      onClick={() => toggleMut.mutate(!subscribed)}
    >
      {subscribed ? (
        <Bell className="h-3.5 w-3.5" aria-hidden />
      ) : (
        <BellOff className="h-3.5 w-3.5 text-muted-foreground" aria-hidden />
      )}
      {subscribed
        ? t('subscriptions.following', 'Seguint')
        : t('subscriptions.follow', 'Seguir')}
    </Button>
  )
}
