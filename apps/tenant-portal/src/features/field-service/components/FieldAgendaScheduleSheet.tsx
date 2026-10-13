import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { ExternalLink } from 'lucide-react'
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetFooter,
  SheetHeader,
  SheetTitle,
} from '@/components/ui/sheet'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useToast } from '@/hooks/use-toast'
import { localDayStartIso } from '@/lib/dateLocal'
import { useUpdateProject } from '@/features/projects/api/useUpdateProject'
import type { FieldVisit } from '../api/fieldVisitsService'

type FieldAgendaScheduleSheetProps = {
  visit: FieldVisit | null
  open: boolean
  onOpenChange: (open: boolean) => void
  onOpenDetail: (id: string) => void
  onSaved?: () => void
}

function toDateTimeLocalValue(iso: string | null | undefined): string {
  if (!iso) return ''
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return ''
  const y = d.getFullYear()
  const m = String(d.getMonth() + 1).padStart(2, '0')
  const day = String(d.getDate()).padStart(2, '0')
  const hh = String(d.getHours()).padStart(2, '0')
  const mm = String(d.getMinutes()).padStart(2, '0')
  return `${y}-${m}-${day}T${hh}:${mm}`
}

function toIsoFromPlannedInput(value: string | null | undefined): string | null {
  if (!value) return null
  if (/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    return localDayStartIso(value)
  }
  const parsed = new Date(value)
  if (!Number.isNaN(parsed.getTime())) return parsed.toISOString()
  return value
}

function getSubmitErrorMessage(
  err: unknown,
  t: (key: string, fallback: string) => string,
): string {
  const raw =
    err instanceof Error
      ? err.message
      : err && typeof err === 'object'
        ? ((err as { message?: string; details?: string; hint?: string }).message ||
            (err as { details?: string }).details ||
            (err as { hint?: string }).hint ||
            '')
        : ''
  if (raw.includes('work_order_requires_site_id')) {
    return t(
      'agenda.schedule.site_required',
      "Cal assignar el local a la fitxa de l'ordre abans de canviar tipus o local.",
    )
  }
  return raw || 'submit_failed'
}

export function FieldAgendaScheduleSheet({
  visit,
  open,
  onOpenChange,
  onOpenDetail,
  onSaved,
}: FieldAgendaScheduleSheetProps) {
  const { t } = useTranslation('field-service')
  const { toast } = useToast()
  const updateProject = useUpdateProject()
  const [plannedStart, setPlannedStart] = useState('')
  const [plannedEnd, setPlannedEnd] = useState('')

  useEffect(() => {
    if (!open || !visit) return
    setPlannedStart(toDateTimeLocalValue(visit.planned_start))
    setPlannedEnd(toDateTimeLocalValue(visit.planned_end))
  }, [open, visit])

  const place = visit
    ? [visit.contact_site_name, visit.contact_site_city].filter(Boolean).join(' · ')
    : ''
  const hasAddress = Boolean(visit?.contact_site_name || visit?.contact_site_city)
  const typeLabel =
    visit?.type === 'maintenance'
      ? t('agenda.filters.maintenance', 'Manteniment')
      : t('agenda.filters.work_order', 'Ordre de servei')
  const modeLabel =
    visit?.service_mode === 'assessment'
      ? t('service_mode.assessment', 'Avaluació')
      : null

  async function handleSave() {
    if (!visit) return
    const startIso = toIsoFromPlannedInput(plannedStart)
    if (!startIso) {
      toast({
        title: t('agenda.schedule.start_required', "Cal una data d'inici"),
        variant: 'destructive',
      })
      return
    }
    const endIso = toIsoFromPlannedInput(plannedEnd)
    if (endIso && new Date(endIso).getTime() < new Date(startIso).getTime()) {
      toast({
        title: t('agenda.schedule.end_before_start', "La fi ha de ser igual o posterior a l'inici"),
        variant: 'destructive',
      })
      return
    }
    try {
      await updateProject.mutateAsync({
        id: visit.id,
        params: {
          planned_start: startIso,
          planned_end: endIso,
        },
      })
      toast({
        title: t('agenda.schedule.saved', 'Dates desades'),
      })
      onOpenChange(false)
      onSaved?.()
    } catch (err) {
      toast({
        title: getSubmitErrorMessage(err, t),
        variant: 'destructive',
      })
    }
  }

  return (
    <Sheet open={open} onOpenChange={onOpenChange}>
      <SheetContent side="right" className="flex w-full flex-col gap-0 p-0 sm:max-w-md">
        <SheetHeader className="border-b border-border px-4 py-3 text-left">
          <SheetTitle>
            {t('agenda.schedule.title', 'Planificar visita')}
          </SheetTitle>
          <SheetDescription className="sr-only">
            {t(
              'agenda.schedule.description',
              'Assigna les dates previstes sense sortir de l’agenda.',
            )}
          </SheetDescription>
        </SheetHeader>

        {visit ? (
          <div className="min-h-0 flex-1 space-y-5 overflow-y-auto p-4">
            <div className="space-y-2">
              <p className="text-base font-semibold leading-snug">{visit.name}</p>
              <dl className="space-y-1.5 text-sm">
                <div className="flex gap-2">
                  <dt className="w-20 shrink-0 text-muted-foreground">
                    {t('agenda.schedule.client', 'Client')}
                  </dt>
                  <dd className="min-w-0 truncate">
                    {visit.client_display_name || '—'}
                  </dd>
                </div>
                <div className="flex gap-2">
                  <dt className="w-20 shrink-0 text-muted-foreground">
                    {t('agenda.schedule.address', 'Adreça')}
                  </dt>
                  <dd className="min-w-0 truncate">{place || '—'}</dd>
                </div>
                <div className="flex gap-2">
                  <dt className="w-20 shrink-0 text-muted-foreground">
                    {t('agenda.schedule.type', 'Tipus')}
                  </dt>
                  <dd className="min-w-0">
                    {[typeLabel, modeLabel].filter(Boolean).join(' · ')}
                  </dd>
                </div>
              </dl>
              <Button
                type="button"
                variant="link"
                className="h-auto px-0 text-sm"
                onClick={() => onOpenDetail(visit.id)}
              >
                <ExternalLink className="mr-1 h-3.5 w-3.5" />
                {t('agenda.schedule.open_detail', 'Obrir fitxa')}
              </Button>
            </div>

            {!hasAddress ? (
              <p className="rounded-lg border border-amber-500/30 bg-amber-500/10 px-3 py-2 text-xs text-amber-900 dark:text-amber-100">
                {t(
                  'agenda.schedule.no_address',
                  "Aquesta ordre no té adreça d'intervencenció. Pots desar les dates i completar l'adreça a la fitxa.",
                )}
              </p>
            ) : null}

            <div className="grid gap-4 sm:grid-cols-2">
              <div className="space-y-1">
                <label className="text-sm font-medium" htmlFor="agenda-schedule-start">
                  {t('agenda.schedule.start', 'Inici previst')}
                </label>
                <Input
                  id="agenda-schedule-start"
                  type="datetime-local"
                  value={plannedStart}
                  onChange={(e) => setPlannedStart(e.target.value)}
                />
              </div>
              <div className="space-y-1">
                <label className="text-sm font-medium" htmlFor="agenda-schedule-end">
                  {t('agenda.schedule.end', 'Fi prevista')}
                </label>
                <Input
                  id="agenda-schedule-end"
                  type="datetime-local"
                  value={plannedEnd}
                  onChange={(e) => setPlannedEnd(e.target.value)}
                />
              </div>
            </div>
          </div>
        ) : null}

        <SheetFooter className="border-t border-border px-4 py-3">
          <Button
            type="button"
            variant="outline"
            onClick={() => onOpenChange(false)}
            disabled={updateProject.isPending}
          >
            {t('agenda.schedule.cancel', 'Cancel·lar')}
          </Button>
          <Button
            type="button"
            onClick={() => void handleSave()}
            disabled={!visit || updateProject.isPending}
          >
            {updateProject.isPending
              ? t('agenda.schedule.saving', 'Desant…')
              : t('agenda.schedule.save', 'Desar dates')}
          </Button>
        </SheetFooter>
      </SheetContent>
    </Sheet>
  )
}
