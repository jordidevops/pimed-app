import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { Loader2 } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Label } from '@/components/ui/label'
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select'
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useToast } from '@/hooks/use-toast'
import { usePermission } from '@/hooks/usePermission'
import { useTenantFeatures } from '@/features/entity-timeline/api/useTenantFeatures'
import type { InboundInboxItem, InboundInboxStatus } from '../api/recruitmentService'
import {
  useAssignRecruitmentInboxItem,
  useDiscardRecruitmentInboxItem,
  useJobPostings,
  useRecruitmentEmailInbox,
} from '../api/useRecruitment'

export function RecruitmentInboundInboxPage() {
  const { t } = useTranslation('recruitment')
  const { toast } = useToast()
  const canView = usePermission('recruitment.view')
  const canManage = usePermission('recruitment.manage')
  const { data: features, isLoading: featuresLoading } = useTenantFeatures()
  const [statusFilter, setStatusFilter] = useState<InboundInboxStatus | 'all'>('unassigned')
  const { data: items = [], isLoading } = useRecruitmentEmailInbox(statusFilter)
  const { data: postings = [] } = useJobPostings()
  const assignMutation = useAssignRecruitmentInboxItem()
  const discardMutation = useDiscardRecruitmentInboxItem()

  const [assignItem, setAssignItem] = useState<InboundInboxItem | null>(null)
  const [postingId, setPostingId] = useState('')

  if (featuresLoading) {
    return (
      <div className="p-6 flex items-center gap-2 text-muted-foreground">
        <Loader2 className="h-4 w-4 animate-spin" />
        {t('inbox.loading')}
      </div>
    )
  }

  if (!features?.recruitment_enabled) {
    return (
      <div className="p-6">
        <p className="text-muted-foreground">{t('postings.disabled')}</p>
      </div>
    )
  }

  if (!canView) {
    return (
      <div className="p-6">
        <p className="text-muted-foreground">{t('inbox.forbidden')}</p>
      </div>
    )
  }

  return (
    <div className="space-y-6">
      <p className="text-sm text-muted-foreground max-w-2xl">{t('inbox.hint')}</p>

      <div className="flex flex-wrap gap-3 items-end">
        <div className="space-y-1.5 min-w-[12rem]">
          <Label>{t('inbox.filter_status')}</Label>
          <Select
            value={statusFilter}
            onValueChange={(v) => setStatusFilter(v as InboundInboxStatus | 'all')}
          >
            <SelectTrigger>
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="unassigned">{t('inbox.status_unassigned')}</SelectItem>
              <SelectItem value="assigned">{t('inbox.status_assigned')}</SelectItem>
              <SelectItem value="discarded">{t('inbox.status_discarded')}</SelectItem>
              <SelectItem value="all">{t('inbox.status_all')}</SelectItem>
            </SelectContent>
          </Select>
        </div>
      </div>

      {isLoading ? (
        <div className="flex items-center gap-2 text-muted-foreground py-8">
          <Loader2 className="h-4 w-4 animate-spin" />
          {t('inbox.loading')}
        </div>
      ) : items.length === 0 ? (
        <p className="text-sm text-muted-foreground">{t('inbox.empty')}</p>
      ) : (
        <ul className="divide-y border rounded-lg">
          {items.map((item) => (
            <li key={item.id} className="p-4 space-y-2">
              <div className="flex flex-wrap items-start justify-between gap-3">
                <div className="min-w-0">
                  <p className="font-medium text-foreground truncate">
                    {item.from_name || item.from_email}
                    <span className="text-muted-foreground font-normal">
                      {' '}
                      &lt;{item.from_email}&gt;
                    </span>
                  </p>
                  <p className="text-sm text-foreground mt-0.5">
                    {item.subject || t('inbox.no_subject')}
                  </p>
                  <p className="text-xs text-muted-foreground mt-1">
                    {new Date(item.received_at).toLocaleString()} ·{' '}
                    {t(`inbox.status_${item.status}`)}
                  </p>
                  {item.body_text ? (
                    <p className="text-sm text-muted-foreground mt-2 line-clamp-3 whitespace-pre-wrap">
                      {item.body_text}
                    </p>
                  ) : null}
                </div>
                {canManage && item.status === 'unassigned' ? (
                  <div className="flex gap-2 shrink-0">
                    <Button
                      type="button"
                      size="sm"
                      onClick={() => {
                        setAssignItem(item)
                        setPostingId('')
                      }}
                    >
                      {t('inbox.assign')}
                    </Button>
                    <Button
                      type="button"
                      size="sm"
                      variant="outline"
                      disabled={discardMutation.isPending}
                      onClick={() => {
                        discardMutation.mutate(
                          { id: item.id, reason: null },
                          {
                            onSuccess: () =>
                              toast({ description: t('inbox.discarded') }),
                            onError: (err: Error) =>
                              toast({
                                variant: 'destructive',
                                description: err.message,
                              }),
                          },
                        )
                      }}
                    >
                      {t('inbox.discard')}
                    </Button>
                  </div>
                ) : null}
                {item.status === 'assigned' && item.assigned_posting_id ? (
                  <Button type="button" size="sm" variant="ghost" asChild>
                    <Link to={`/recruitment/postings/${item.assigned_posting_id}`}>
                      {t('inbox.open_posting')}
                    </Link>
                  </Button>
                ) : null}
              </div>
            </li>
          ))}
        </ul>
      )}

      <Dialog open={Boolean(assignItem)} onOpenChange={(o) => !o && setAssignItem(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{t('inbox.assign_title')}</DialogTitle>
          </DialogHeader>
          <div className="space-y-2 py-2">
            <Label>{t('inbox.select_posting')}</Label>
            <Select value={postingId} onValueChange={setPostingId}>
              <SelectTrigger>
                <SelectValue placeholder={t('inbox.select_posting')} />
              </SelectTrigger>
              <SelectContent>
                {postings.map((p) => (
                  <SelectItem key={p.id} value={p.id}>
                    {p.title}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
          <DialogFooter>
            <Button type="button" variant="outline" onClick={() => setAssignItem(null)}>
              {t('inbox.cancel')}
            </Button>
            <Button
              type="button"
              disabled={!postingId || assignMutation.isPending}
              onClick={() => {
                if (!assignItem || !postingId) return
                assignMutation.mutate(
                  { id: assignItem.id, jobPostingId: postingId },
                  {
                    onSuccess: () => {
                      toast({ description: t('inbox.assigned') })
                      setAssignItem(null)
                    },
                    onError: (err: Error) =>
                      toast({ variant: 'destructive', description: err.message }),
                  },
                )
              }}
            >
              {t('inbox.confirm_assign')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}
