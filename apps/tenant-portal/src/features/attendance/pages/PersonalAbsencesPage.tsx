import { useMemo, useState } from 'react'
import { CalendarOff, ChevronLeft, ChevronRight, Plus } from 'lucide-react'
import { useTranslation } from 'react-i18next'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import {
  useAbsenceTypeConfigs,
  useCancelMyAbsence,
  useMyAbsences,
} from '../api/useAbsences'
import { useAttendanceAccess } from '../hooks/useAttendanceAccess'
import { RequestAbsenceDialog } from '../components/RequestAbsenceDialog'
import type { EmployeeAbsence } from '../api/shiftsService'

const PAGE_SIZE = 8

export function PersonalAbsencesPage() {
  const { t, i18n } = useTranslation('attendance')
  const access = useAttendanceAccess()
  const [page, setPage] = useState(0)
  const [requestOpen, setRequestOpen] = useState(false)
  const [withdrawTarget, setWithdrawTarget] = useState<EmployeeAbsence | null>(null)
  const [withdrawReason, setWithdrawReason] = useState('')
  const cancelMutation = useCancelMyAbsence()
  const employeeId = access.employee?.id ?? null

  const year = new Date().getFullYear()
  const from = `${year - 2}-01-01`
  const to = `${year + 1}-12-31`
  const absencesQuery = useMyAbsences(employeeId, from, to)
  const { data: typeConfigs = [] } = useAbsenceTypeConfigs(false, true)
  const typeNames = useMemo(
    () =>
      new Map(
        typeConfigs.map((cfg) => [
          cfg.absence_type,
          cfg.name_i18n?.[i18n.language?.slice(0, 2) ?? 'ca'] ??
            cfg.name_i18n?.ca ??
            cfg.name_i18n?.es ??
            cfg.absence_type,
        ]),
      ),
    [i18n.language, typeConfigs],
  )

  const rows = absencesQuery.data ?? []
  const pageCount = Math.max(1, Math.ceil(rows.length / PAGE_SIZE))
  const safePage = Math.min(page, pageCount - 1)
  const visibleRows = rows.slice(safePage * PAGE_SIZE, (safePage + 1) * PAGE_SIZE)

  if (!access.canRequestAbsence) {
    return (
      <div className="mx-auto max-w-lg px-4 py-12 text-center text-sm text-muted-foreground">
        {t(
          'absences.no_request_permission',
          "No tens permís per sol·licitar absències.",
        )}
      </div>
    )
  }

  return (
    <div className="mx-auto max-w-lg space-y-4 px-4 py-6">
      <div className="flex items-start justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold">
            {t('absences.personal_title', 'Les meves absències')}
          </h1>
          <p className="mt-1 text-sm text-muted-foreground">
            {t(
              'absences.personal_help',
              "Consulta l'estat de les sol·licituds o envia'n una de nova.",
            )}
          </p>
        </div>
        <Button size="sm" className="shrink-0 gap-1" onClick={() => setRequestOpen(true)}>
          <Plus className="h-4 w-4" aria-hidden />
          {t('absences.new_request', 'Nova')}
        </Button>
      </div>

      {absencesQuery.isLoading ? (
        <div className="py-12 text-center text-sm text-muted-foreground">
          {t('absences.loading', 'Carregant absències...')}
        </div>
      ) : rows.length === 0 ? (
        <div className="rounded-2xl border border-dashed p-10 text-center">
          <CalendarOff className="mx-auto mb-3 h-8 w-8 text-muted-foreground" />
          <p className="text-sm text-muted-foreground">
            {t('absences.personal_empty', 'Encara no tens cap sol·licitud.')}
          </p>
        </div>
      ) : (
        <div className="space-y-3">
          {visibleRows.map((absence) => (
            <article key={absence.id} className="rounded-2xl border bg-card p-4">
              <div className="flex items-start justify-between gap-3">
                <div className="min-w-0">
                  <p className="font-medium">
                    {typeNames.get(absence.absence_type ?? '') ??
                      absence.absence_type ??
                      t('absences.type_other', 'Absència')}
                  </p>
                  <p className="mt-1 text-sm text-muted-foreground">
                    {absence.start_date} · {absence.end_date}
                  </p>
                  {absence.notes && (
                    <p className="mt-2 line-clamp-2 text-sm text-muted-foreground">
                      {absence.notes}
                    </p>
                  )}
                </div>
                <Badge variant="outline">
                  {t(
                    `absences.status.${absence.status ?? 'requested'}`,
                    absence.status ?? 'requested',
                  )}
                </Badge>
              </div>
              {absence.status === 'requested' && (
                <Button
                  size="sm"
                  variant="ghost"
                  className="mt-3 text-destructive hover:text-destructive"
                  onClick={() => {
                    setWithdrawReason('')
                    setWithdrawTarget(absence)
                  }}
                >
                  {t('absences.withdraw', 'Retirar sol·licitud')}
                </Button>
              )}
            </article>
          ))}

          <div className="flex items-center justify-between gap-3 pt-1 text-xs text-muted-foreground">
            <span>
              {t('absences.showing_count', 'Mostrant {{shown}} de {{total}}', {
                shown: Math.min((safePage + 1) * PAGE_SIZE, rows.length),
                total: rows.length,
              })}
            </span>
            <div className="flex gap-1">
              <Button
                size="icon"
                variant="outline"
                className="h-8 w-8"
                disabled={safePage === 0}
                onClick={() => setPage((value) => Math.max(0, value - 1))}
                aria-label={t('absences.previous_page', 'Pàgina anterior')}
              >
                <ChevronLeft className="h-4 w-4" />
              </Button>
              <Button
                size="icon"
                variant="outline"
                className="h-8 w-8"
                disabled={safePage >= pageCount - 1}
                onClick={() => setPage((value) => Math.min(pageCount - 1, value + 1))}
                aria-label={t('absences.next_page', 'Pàgina següent')}
              >
                <ChevronRight className="h-4 w-4" />
              </Button>
            </div>
          </div>
        </div>
      )}

      {requestOpen && employeeId && (
        <RequestAbsenceDialog employeeId={employeeId} onClose={() => setRequestOpen(false)} />
      )}

      <Dialog
        open={Boolean(withdrawTarget)}
        onOpenChange={(open) => {
          if (!open && !cancelMutation.isPending) setWithdrawTarget(null)
        }}
      >
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>
              {t('absences.withdraw_confirm_title', 'Retirar aquesta sol·licitud?')}
            </DialogTitle>
          </DialogHeader>
          <p className="text-sm text-muted-foreground">
            {t(
              'absences.withdraw_confirm_help',
              "L'estat passarà a cancel·lada i el gestor ja no l'haurà d'aprovar.",
            )}
          </p>
          <label className="space-y-1 text-sm">
            <span>{t('absences.withdraw_reason', 'Motiu (opcional)')}</span>
            <textarea
              value={withdrawReason}
              onChange={(event) => setWithdrawReason(event.target.value)}
              rows={2}
              className="w-full resize-none rounded-md border bg-background px-3 py-2"
            />
          </label>
          <div className="flex justify-end gap-2">
            <Button
              variant="outline"
              disabled={cancelMutation.isPending}
              onClick={() => setWithdrawTarget(null)}
            >
              {t('absences.keep_request', 'Mantenir')}
            </Button>
            <Button
              variant="destructive"
              disabled={!withdrawTarget || cancelMutation.isPending}
              onClick={() => {
                if (!withdrawTarget?.id) return
                cancelMutation.mutate(
                  { absenceId: withdrawTarget.id, reason: withdrawReason },
                  { onSuccess: () => setWithdrawTarget(null) },
                )
              }}
            >
              {t('absences.withdraw_confirm', 'Retirar')}
            </Button>
          </div>
        </DialogContent>
      </Dialog>
    </div>
  )
}
