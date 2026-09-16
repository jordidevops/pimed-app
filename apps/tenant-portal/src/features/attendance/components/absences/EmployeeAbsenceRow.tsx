import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Check, LogOut, X } from 'lucide-react'
import type { EmployeeAbsence, AbsenceTypeConfig } from '../../api/shiftsService'
import { useApproveAbsence, useRevokeAbsence } from '../../api/useAbsences'
import { useFormatAttendanceDate } from '../../hooks/useFormatAttendanceDate'
import { ABSENCE_STATUS_COLORS, absenceTypeLabel } from './absenceUiUtils'
import { CloseITDialog } from './CloseITDialog'
import { Button } from '@/components/ui/button'
import { Dialog, DialogContent, DialogHeader, DialogTitle } from '@/components/ui/dialog'

interface EmployeeAbsenceRowProps {
  absence: EmployeeAbsence
  typeCfg?: AbsenceTypeConfig
  lang: string
  isManager: boolean
  showEmployeeName?: boolean
  employeeName?: string
}

export function EmployeeAbsenceRow({
  absence,
  typeCfg,
  lang,
  isManager,
  showEmployeeName = false,
  employeeName,
}: EmployeeAbsenceRowProps) {
  const { t } = useTranslation('attendance')
  const formatDate = useFormatAttendanceDate()
  const { mutate: approve, isPending } = useApproveAbsence()
  const revoke = useRevokeAbsence()
  const [closeOpen, setCloseOpen] = useState(false)
  const [revokeOpen, setRevokeOpen] = useState(false)
  const [revokeReason, setRevokeReason] = useState('')

  const typeLabel = absenceTypeLabel(typeCfg, absence.absence_type ?? '?', lang)
  const isIT = typeCfg?.is_it ?? false
  const partialStart = (absence as { partial_start_time?: string | null }).partial_start_time
  const partialEnd = (absence as { partial_end_time?: string | null }).partial_end_time
  const isPartial = Boolean(partialStart && partialEnd)

  return (
    <>
      <div className="flex flex-col gap-3 rounded-lg border p-4 sm:flex-row sm:items-start">
        <div className="min-w-0 flex-1">
          {showEmployeeName && employeeName ? (
            <p className="mb-1 text-sm font-semibold">{employeeName}</p>
          ) : null}
          <div className="mb-1 flex flex-wrap items-center gap-2">
            <span
              className={`rounded-full px-2 py-0.5 text-xs font-medium ${
                isIT ? 'bg-blue-100 text-blue-800' : 'bg-purple-100 text-purple-800'
              }`}
            >
              {typeLabel}
            </span>
            <span
              className={`rounded-full border px-2 py-0.5 text-xs font-medium ${
                ABSENCE_STATUS_COLORS[absence.status ?? 'requested'] ?? ABSENCE_STATUS_COLORS.requested
              }`}
            >
              {t(`absences.status.${absence.status ?? 'requested'}`, absence.status ?? 'requested')}
            </span>
            {isPartial ? (
              <span className="rounded-full bg-amber-100 px-2 py-0.5 text-xs text-amber-800">
                {t('absences.partial', 'Parcial')}
              </span>
            ) : null}
          </div>
          <p className="text-sm font-medium">
            {formatDate(absence.start_date)}
            {absence.end_date && absence.end_date !== absence.start_date
              ? ` → ${formatDate(absence.end_date)}`
              : ''}
          </p>
          {isPartial ? (
            <p className="text-xs text-muted-foreground">
              {partialStart} – {partialEnd}
            </p>
          ) : null}
          {absence.notes ? (
            <p className="mt-1 truncate text-xs text-muted-foreground">{absence.notes}</p>
          ) : null}
          {absence.review_comment ? (
            <p className="mt-1 text-xs italic text-muted-foreground">
              {t('absences.review_comment', 'Comentari')}: {absence.review_comment}
            </p>
          ) : null}
        </div>

        {isManager ? (
          <div className="flex shrink-0 flex-wrap gap-2">
            {absence.status === 'requested' ? (
              <>
                <button
                  type="button"
                  onClick={() => approve({ absenceId: absence.id ?? '', newStatus: 'approved' })}
                  disabled={isPending}
                  className="flex items-center gap-1 rounded-md bg-green-100 px-2.5 py-1.5 text-xs text-green-800 hover:bg-green-200 disabled:opacity-50"
                >
                  <Check className="h-3 w-3" />
                  {t('absences.approve', 'Aprovar')}
                </button>
                <button
                  type="button"
                  onClick={() => approve({ absenceId: absence.id ?? '', newStatus: 'rejected' })}
                  disabled={isPending}
                  className="flex items-center gap-1 rounded-md bg-red-100 px-2.5 py-1.5 text-xs text-red-800 hover:bg-red-200 disabled:opacity-50"
                >
                  <X className="h-3 w-3" />
                  {t('absences.reject', 'Rebutjar')}
                </button>
              </>
            ) : null}
            {!isIT && absence.status === 'approved' ? (
              <button
                type="button"
                onClick={() => setRevokeOpen(true)}
                disabled={revoke.isPending}
                className="flex items-center gap-1 rounded-md bg-amber-100 px-2.5 py-1.5 text-xs text-amber-900 hover:bg-amber-200 disabled:opacity-50"
              >
                <X className="h-3 w-3" />
                {t('absences.revoke', 'Revocar')}
              </button>
            ) : null}
            {isIT && absence.status === 'active' ? (
              <button
                type="button"
                onClick={() => setCloseOpen(true)}
                className="flex items-center gap-1 rounded-md bg-blue-100 px-2.5 py-1.5 text-xs text-blue-800 hover:bg-blue-200"
              >
                <LogOut className="h-3 w-3" />
                {t('absences.close_it', 'Registrar alta')}
              </button>
            ) : null}
          </div>
        ) : null}
      </div>

      <CloseITDialog absence={absence} open={closeOpen} onOpenChange={setCloseOpen} />
      <Dialog open={revokeOpen} onOpenChange={setRevokeOpen}>
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>{t('absences.revoke_title', "Revocar l'aprovació")}</DialogTitle>
          </DialogHeader>
          <label className="space-y-1 text-sm">
            <span>{t('absences.revoke_reason', 'Motiu')}</span>
            <textarea
              value={revokeReason}
              onChange={(event) => setRevokeReason(event.target.value)}
              rows={3}
              required
              className="w-full resize-none rounded-md border bg-background px-3 py-2"
            />
          </label>
          <div className="flex justify-end gap-2">
            <Button variant="outline" onClick={() => setRevokeOpen(false)}>
              {t('absences.form.cancel', 'Cancel·lar')}
            </Button>
            <Button
              variant="destructive"
              disabled={!revokeReason.trim() || revoke.isPending}
              onClick={() => {
                if (!absence.id) return
                revoke.mutate(
                  { absenceId: absence.id, reason: revokeReason },
                  {
                    onSuccess: () => {
                      setRevokeOpen(false)
                      setRevokeReason('')
                    },
                  },
                )
              }}
            >
              {t('absences.revoke_confirm', 'Revocar')}
            </Button>
          </div>
        </DialogContent>
      </Dialog>
    </>
  )
}
