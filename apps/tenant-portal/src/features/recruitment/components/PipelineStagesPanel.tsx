import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Plus, Trash2 } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
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
  createPipelineStage,
  deletePipelineStage,
  listTenantDefaultPipelineStages,
  updatePipelineStage,
  type PipelineStage,
} from '../api/recruitmentService'
import { recruitmentKeys } from '../api/useRecruitment'

export function PipelineStagesPanel() {
  const { t } = useTranslation('recruitment')
  const { activeTenant } = useTenant()
  const canManage = usePermission('recruitment.manage')
  const { toast } = useToast()
  const qc = useQueryClient()
  const [newName, setNewName] = useState('')
  const [stageToDelete, setStageToDelete] = useState<PipelineStage | null>(null)

  const { data: stages = [] } = useQuery({
    queryKey: [...recruitmentKeys.all, 'tenant-stages', activeTenant?.id],
    enabled: Boolean(activeTenant?.id && canManage),
    queryFn: () => listTenantDefaultPipelineStages(activeTenant!.id),
  })

  const invalidate = () => {
    void qc.invalidateQueries({ queryKey: recruitmentKeys.all })
  }

  const addMutation = useMutation({
    mutationFn: async () => {
      if (!activeTenant?.id || !newName.trim()) return
      const maxPos = stages.reduce((m, s) => Math.max(m, s.position), -1)
      await createPipelineStage({
        tenantId: activeTenant.id,
        name: newName,
        position: maxPos + 1,
      })
    },
    onSuccess: () => {
      setNewName('')
      invalidate()
      toast({ description: t('form.save') })
    },
    onError: (err: Error) => toast({ variant: 'destructive', description: err.message }),
  })

  const updateMutation = useMutation({
    mutationFn: async (stage: PipelineStage) => {
      await updatePipelineStage(stage.id, {
        name: stage.name,
        position: stage.position,
        is_terminal_hire: stage.is_terminal_hire,
        is_terminal_reject: stage.is_terminal_reject,
      })
    },
    onSuccess: () => {
      invalidate()
      toast({ description: t('form.save') })
    },
    onError: (err: Error) => toast({ variant: 'destructive', description: err.message }),
  })

  const deleteMutation = useMutation({
    mutationFn: (id: string) => deletePipelineStage(id),
    onSuccess: () => {
      setStageToDelete(null)
      invalidate()
      toast({ description: t('stages.deleted') })
    },
    onError: (err: Error) => toast({ variant: 'destructive', description: err.message }),
  })

  if (!canManage) return null

  return (
    <div className="space-y-4 rounded-xl border p-4 sm:p-5">
      <div>
        <h2 className="font-semibold">{t('stages.title')}</h2>
        <p className="mt-1 text-sm text-muted-foreground">{t('stages.hub_intro')}</p>
      </div>

      <ul className="space-y-3">
        {stages.map((stage) => (
          <li key={stage.id} className="flex flex-wrap items-end gap-2 border-b pb-3 last:border-0">
            <div className="space-y-1 min-w-[10rem] flex-1">
              <Label className="text-xs">{t('stages.name')}</Label>
              <Input
                defaultValue={stage.name}
                onBlur={(e) => {
                  const name = e.target.value.trim()
                  if (name && name !== stage.name) {
                    updateMutation.mutate({ ...stage, name })
                  }
                }}
              />
            </div>
            <div className="space-y-1 w-20">
              <Label className="text-xs">{t('stages.position')}</Label>
              <Input
                type="number"
                defaultValue={stage.position}
                onBlur={(e) => {
                  const position = Number(e.target.value)
                  if (!Number.isNaN(position) && position !== stage.position) {
                    updateMutation.mutate({ ...stage, position })
                  }
                }}
              />
            </div>
            <label className="flex items-center gap-1.5 text-xs pb-2">
              <input
                type="checkbox"
                checked={stage.is_terminal_hire}
                onChange={(e) =>
                  updateMutation.mutate({ ...stage, is_terminal_hire: e.target.checked })
                }
              />
              {t('stages.hire')}
            </label>
            <label className="flex items-center gap-1.5 text-xs pb-2">
              <input
                type="checkbox"
                checked={stage.is_terminal_reject}
                onChange={(e) =>
                  updateMutation.mutate({ ...stage, is_terminal_reject: e.target.checked })
                }
              />
              {t('stages.reject')}
            </label>
            <Button
              type="button"
              variant="ghost"
              size="icon"
              className="shrink-0"
              disabled={deleteMutation.isPending}
              onClick={() => setStageToDelete(stage)}
              aria-label={t('stages.delete')}
            >
              <Trash2 className="h-4 w-4" />
            </Button>
          </li>
        ))}
      </ul>

      <div className="flex flex-wrap gap-2 items-end">
        <div className="space-y-1 flex-1 min-w-[12rem]">
          <Label>{t('stages.add')}</Label>
          <Input
            value={newName}
            onChange={(e) => setNewName(e.target.value)}
            placeholder={t('stages.name_placeholder')}
          />
        </div>
        <Button
          type="button"
          variant="outline"
          disabled={!newName.trim() || addMutation.isPending}
          onClick={() => addMutation.mutate()}
        >
          <Plus className="mr-2 h-4 w-4" />
          {t('stages.add')}
        </Button>
      </div>

      <Dialog
        open={Boolean(stageToDelete)}
        onOpenChange={(open) => {
          if (!open) setStageToDelete(null)
        }}
      >
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>{t('stages.delete_confirm_title')}</DialogTitle>
            <DialogDescription>
              {t('stages.delete_confirm', { name: stageToDelete?.name ?? '' })}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter className="gap-2">
            <Button
              type="button"
              variant="outline"
              disabled={deleteMutation.isPending}
              onClick={() => setStageToDelete(null)}
            >
              {t('stages.cancel')}
            </Button>
            <Button
              type="button"
              variant="destructive"
              disabled={deleteMutation.isPending || !stageToDelete}
              onClick={() => {
                if (stageToDelete) deleteMutation.mutate(stageToDelete.id)
              }}
            >
              {deleteMutation.isPending ? t('stages.working') : t('stages.delete')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}
