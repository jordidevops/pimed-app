import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { FileStack, Loader2 } from 'lucide-react'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { Label } from '@/components/ui/label'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { useSites } from '@/hooks/useSites'
import { useAuth } from '@/contexts/AuthContext'
import { useCalendarGroups } from '../../api/useLaborCalendar'
import {
  useEnqueueProtocolBulkPublish,
  useProtocolBulkJobStatus,
} from '../../api/useProtocolBulkPublish'
import type { ProtocolBulkScope } from '../../api/protocolBulkPublishService'

interface AttendanceProtocolBulkPublishDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
}

export function AttendanceProtocolBulkPublishDialog({
  open,
  onOpenChange,
}: AttendanceProtocolBulkPublishDialogProps) {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const { activeTenant } = useTenant()
  const { user } = useAuth()
  const { data: sites = [] } = useSites(activeTenant?.id ?? null, user?.id, 'active')

  const [scope, setScope] = useState<ProtocolBulkScope>('all_active')
  const [siteId, setSiteId] = useState<string>('')
  const [calendarGroupId, setCalendarGroupId] = useState<string>('')
  const [activeJobId, setActiveJobId] = useState<string | null>(null)

  const { data: calendarGroups = [] } = useCalendarGroups(
    scope === 'calendar_group' && siteId ? siteId : null,
  )

  const enqueue = useEnqueueProtocolBulkPublish()
  const { data: jobStatus } = useProtocolBulkJobStatus(activeJobId, open && !!activeJobId)

  useEffect(() => {
    if (!open) {
      setActiveJobId(null)
      setScope('all_active')
      setSiteId('')
      setCalendarGroupId('')
    }
  }, [open])

  useEffect(() => {
    if (!jobStatus) return
    if (jobStatus.status === 'completed' || jobStatus.status === 'partial' || jobStatus.status === 'failed') {
      const title =
        jobStatus.status === 'completed'
          ? t('protocol.bulk_done', 'Publicació completada')
          : jobStatus.status === 'partial'
          ? t('protocol.bulk_partial', 'Publicació parcial')
          : t('protocol.bulk_failed', 'Publicació fallida')

      toast({
        title,
        description: t('protocol.bulk_summary', '{{ok}} correctes, {{fail}} errors, {{skip}} omesos (de {{total}})', {
          ok: jobStatus.succeeded_count,
          fail: jobStatus.failed_count,
          skip: jobStatus.skipped_count,
          total: jobStatus.total_count,
        }),
      })
    }
  }, [jobStatus?.status, jobStatus?.succeeded_count, jobStatus?.failed_count, jobStatus?.skipped_count, jobStatus?.total_count, t, toast])

  async function handleStart() {
    if (!activeTenant?.id) return

    if (scope === 'site' && !siteId) {
      toast({
        variant: 'destructive',
        description: t('protocol.bulk_site_required', 'Selecciona un centre'),
      })
      return
    }

    if (scope === 'calendar_group' && !calendarGroupId) {
      toast({
        variant: 'destructive',
        description: t('protocol.bulk_group_required', 'Selecciona un grup de conveni'),
      })
      return
    }

    try {
      const result = await enqueue.mutateAsync({
        scope,
        siteId: scope === 'site' ? siteId : null,
        calendarGroupId: scope === 'calendar_group' ? calendarGroupId : null,
      })

      if (result.total_count === 0) {
        toast({
          variant: 'destructive',
          description: t('protocol.bulk_empty', 'Cap empleat actiu al filtre seleccionat'),
        })
        return
      }

      setActiveJobId(result.job_id)
      toast({
        title: t('protocol.bulk_started', 'Publicació en curs'),
        description: t(
          'protocol.bulk_started_desc',
          "S'estan publicant {{count}} protocols en segon pla (màx. 500).",
          { count: result.total_count },
        ),
      })
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('protocol.bulk_error', 'No s\'ha pogut iniciar la publicació'),
        description: err instanceof Error ? err.message : String(err),
      })
    }
  }

  const isRunning =
    !!activeJobId &&
    jobStatus &&
    !['completed', 'partial', 'failed'].includes(jobStatus.status)

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            <FileStack className="h-5 w-5" />
            {t('protocol.bulk_title', 'Publicació massiva de protocol')}
          </DialogTitle>
          <DialogDescription>
            {t(
              'protocol.bulk_desc',
              'Genera i assigna el protocol horari a diversos empleats. El procés és asíncron amb límit de velocitat.',
            )}
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-4 py-2">
          <div className="space-y-2">
            <Label>{t('protocol.bulk_scope', 'Àmbit')}</Label>
            <select
              className="w-full border rounded-md h-9 px-2 text-sm bg-background"
              value={scope}
              disabled={isRunning || enqueue.isPending}
              onChange={(e) => {
                setScope(e.target.value as ProtocolBulkScope)
                setSiteId('')
                setCalendarGroupId('')
              }}
            >
              <option value="all_active">
                {t('protocol.bulk_scope_all', 'Tots els empleats actius')}
              </option>
              <option value="site">
                {t('protocol.bulk_scope_site', 'Per centre')}
              </option>
              <option value="calendar_group">
                {t('protocol.bulk_scope_group', 'Per grup de conveni')}
              </option>
            </select>
          </div>

          {scope === 'site' && (
            <div className="space-y-2">
              <Label>{t('protocol.bulk_site', 'Centre')}</Label>
              <select
                className="w-full border rounded-md h-9 px-2 text-sm bg-background"
                value={siteId}
                disabled={isRunning || enqueue.isPending}
                onChange={(e) => setSiteId(e.target.value)}
              >
                <option value="">{t('protocol.bulk_select_site', 'Selecciona…')}</option>
                {sites.map((s) => (
                  <option key={s.id} value={s.id}>
                    {s.name}
                  </option>
                ))}
              </select>
            </div>
          )}

          {scope === 'calendar_group' && (
            <>
              <div className="space-y-2">
                <Label>{t('protocol.bulk_site_filter', 'Centre (filtre)')}</Label>
                <select
                  className="w-full border rounded-md h-9 px-2 text-sm bg-background"
                  value={siteId}
                  disabled={isRunning || enqueue.isPending}
                  onChange={(e) => {
                    setSiteId(e.target.value)
                    setCalendarGroupId('')
                  }}
                >
                  <option value="">{t('protocol.bulk_all_sites', 'Tots els centres')}</option>
                  {sites.map((s) => (
                    <option key={s.id} value={s.id}>
                      {s.name}
                    </option>
                  ))}
                </select>
              </div>
              <div className="space-y-2">
                <Label>{t('protocol.bulk_calendar_group', 'Grup de conveni')}</Label>
                <select
                  className="w-full border rounded-md h-9 px-2 text-sm bg-background"
                  value={calendarGroupId}
                  disabled={isRunning || enqueue.isPending}
                  onChange={(e) => setCalendarGroupId(e.target.value)}
                >
                  <option value="">{t('protocol.bulk_select_group', 'Selecciona…')}</option>
                  {calendarGroups.map((g) => (
                    <option key={g.id} value={g.id}>
                      {g.name}
                    </option>
                  ))}
                </select>
              </div>
            </>
          )}

          {jobStatus && (
            <div className="rounded-lg border bg-muted/30 p-3 text-sm space-y-1">
              <p className="font-medium">
                {t('protocol.bulk_progress', 'Progrés')}: {jobStatus.succeeded_count + jobStatus.failed_count + jobStatus.skipped_count} / {jobStatus.total_count}
              </p>
              <p className="text-muted-foreground text-xs">
                {t('protocol.bulk_status_label', 'Estat')}: {jobStatus.status}
              </p>
              {jobStatus.failed_count > 0 && (
                <ul className="text-xs text-destructive mt-2 space-y-0.5 max-h-24 overflow-y-auto">
                  {jobStatus.failed_items.slice(0, 5).map((item) => (
                    <li key={item.id}>
                      {item.employee_id.slice(0, 8)}… — {item.error_message}
                    </li>
                  ))}
                </ul>
              )}
            </div>
          )}
        </div>

        <DialogFooter>
          <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>
            {t('protocol.bulk_close', 'Tancar')}
          </Button>
          <Button
            type="button"
            onClick={() => void handleStart()}
            disabled={isRunning || enqueue.isPending}
          >
            {(isRunning || enqueue.isPending) && (
              <Loader2 className="mr-1.5 h-4 w-4 animate-spin" />
            )}
            {isRunning
              ? t('protocol.bulk_running', 'Publicant…')
              : t('protocol.bulk_start', 'Iniciar publicació')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
