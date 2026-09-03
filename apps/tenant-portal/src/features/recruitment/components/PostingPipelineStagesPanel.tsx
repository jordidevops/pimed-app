import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useTenant } from '@/contexts/TenantContext'
import { useToast } from '@/hooks/use-toast'
import { usePermission } from '@/hooks/usePermission'
import {
  clonePipelineStagesToPosting,
  deletePipelineStageOverride,
  listPostingOverridePipelineStages,
} from '../api/recruitmentService'
import { recruitmentKeys } from '../api/useRecruitment'

interface Props {
  jobPostingId: string
}

export function PostingPipelineStagesPanel({ jobPostingId }: Props) {
  const { t } = useTranslation('recruitment')
  const { activeTenant } = useTenant()
  const canManage = usePermission('recruitment.manage')
  const { toast } = useToast()
  const qc = useQueryClient()
  const [resetOpen, setResetOpen] = useState(false)

  const { data: overrides = [] } = useQuery({
    queryKey: [...recruitmentKeys.all, 'posting-override-stages', jobPostingId],
    enabled: Boolean(activeTenant?.id && canManage && jobPostingId),
    queryFn: () => listPostingOverridePipelineStages(activeTenant!.id, jobPostingId),
  })

  const hasOverride = overrides.length > 0

  const invalidate = () => {
    void qc.invalidateQueries({ queryKey: recruitmentKeys.all })
  }

  const cloneMutation = useMutation({
    mutationFn: () => clonePipelineStagesToPosting(jobPostingId),
    onSuccess: (res) => {
      invalidate()
      toast({ description: t('stages.cloned', { count: res.cloned }) })
    },
    onError: (err: Error) => toast({ variant: 'destructive', description: err.message }),
  })

  const resetMutation = useMutation({
    mutationFn: () => deletePipelineStageOverride(jobPostingId),
    onSuccess: () => {
      setResetOpen(false)
      invalidate()
      toast({ description: t('stages.reset_ok') })
    },
    onError: (err: Error) => toast({ variant: 'destructive', description: err.message }),
  })

  if (!canManage) return null

  return (
    <div className="rounded-lg border p-4 space-y-3">
      <div>
        <h2 className="font-semibold text-sm">{t('stages.posting_title')}</h2>
        <p className="text-xs text-muted-foreground mt-1">{t('stages.posting_hint')}</p>
      </div>
      {hasOverride ? (
        <>
          <p className="text-sm">
            {t('stages.posting_override_active', { count: overrides.length })}
          </p>
          <ul className="text-sm text-muted-foreground list-disc pl-5">
            {overrides.map((s) => (
              <li key={s.id}>
                {s.name}
                {s.is_terminal_hire ? ` (${t('stages.hire')})` : ''}
                {s.is_terminal_reject ? ` (${t('stages.reject')})` : ''}
              </li>
            ))}
          </ul>
          <Button
            type="button"
            variant="outline"
            size="sm"
            disabled={resetMutation.isPending}
            onClick={() => setResetOpen(true)}
          >
            {t('stages.reset')}
          </Button>
        </>
      ) : (
        <>
          <p className="text-sm text-muted-foreground">{t('stages.using_tenant_defaults')}</p>
          <Button
            type="button"
            variant="outline"
            size="sm"
            disabled={cloneMutation.isPending}
            onClick={() => cloneMutation.mutate()}
          >
            {t('stages.clone')}
          </Button>
        </>
      )}

      <Dialog open={resetOpen} onOpenChange={setResetOpen}>
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>{t('stages.reset_confirm_title')}</DialogTitle>
            <DialogDescription>{t('stages.reset_confirm')}</DialogDescription>
          </DialogHeader>
          <DialogFooter className="gap-2">
            <Button
              type="button"
              variant="outline"
              disabled={resetMutation.isPending}
              onClick={() => setResetOpen(false)}
            >
              {t('stages.cancel')}
            </Button>
            <Button
              type="button"
              variant="destructive"
              disabled={resetMutation.isPending}
              onClick={() => resetMutation.mutate()}
            >
              {resetMutation.isPending ? t('stages.working') : t('stages.reset')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}
