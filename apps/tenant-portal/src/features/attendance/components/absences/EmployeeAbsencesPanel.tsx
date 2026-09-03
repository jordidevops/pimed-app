import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { CalendarOff, ExternalLink, Loader2, Plus, Stethoscope } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { useMyAbsences, useAbsenceTypeConfigs } from '../../api/useAbsences'
import { RequestAbsenceDialog } from '../RequestAbsenceDialog'
import { EmployeeAbsenceRow } from './EmployeeAbsenceRow'
import { RegisterITDialog } from './RegisterITDialog'

interface EmployeeAbsencesPanelProps {
  employeeId: string
  employeeName?: string
  canManage: boolean
  /** Amaga botons ràpids quan la barra manager (B4) ja els mostra. */
  hideQuickActions?: boolean
}

function absencePeriodBounds() {
  const year = new Date().getFullYear()
  return { from: `${year - 1}-01-01`, to: `${year + 1}-12-31` }
}

export function EmployeeAbsencesPanel({
  employeeId,
  employeeName,
  canManage,
  hideQuickActions = false,
}: EmployeeAbsencesPanelProps) {
  const { t, i18n } = useTranslation('attendance')
  const lang = i18n.language?.slice(0, 2) ?? 'ca'
  const { from, to } = useMemo(() => absencePeriodBounds(), [])

  const { data: absences = [], isLoading } = useMyAbsences(employeeId, from, to)
  const { data: typeConfigs = [] } = useAbsenceTypeConfigs(true, true)

  const [registerItOpen, setRegisterItOpen] = useState(false)
  const [requestAbsenceOpen, setRequestAbsenceOpen] = useState(false)

  const typeConfigMap = useMemo(
    () => Object.fromEntries(typeConfigs.map((c) => [c.absence_type, c])),
    [typeConfigs],
  )
  const itTypeConfigs = useMemo(() => typeConfigs.filter((c) => c.is_it), [typeConfigs])

  const pendingCount = absences.filter((a) => a.status === 'requested').length
  const activeItCount = absences.filter(
    (a) => a.status === 'active' && typeConfigMap[a.absence_type ?? '']?.is_it,
  ).length

  if (!canManage) return null

  return (
    <div className="space-y-3 rounded-xl border bg-card p-4 shadow-sm">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h3 className="flex items-center gap-2 text-base font-semibold">
            <CalendarOff className="h-4 w-4 text-muted-foreground" />
            {t('absences.employee_panel_title', 'Absències i IT')}
          </h3>
          <p className="text-sm text-muted-foreground">
            {t(
              'absences.employee_panel_desc',
              'Registra baixes mèdiques o absències per a aquest empleat. Els canvis es reflecteixen al calendari i a la revisió de nòmina.',
            )}
          </p>
          <div className="mt-1 flex flex-wrap gap-3 text-xs">
            {pendingCount > 0 ? (
              <span className="text-amber-700">
                {t('absences.pending_count', '{{count}} pendents d’aprovació', { count: pendingCount })}
              </span>
            ) : null}
            {activeItCount > 0 ? (
              <span className="text-blue-700">
                {t('absences.active_it_count', '{{count}} IT actives', { count: activeItCount })}
              </span>
            ) : null}
          </div>
        </div>
        {!hideQuickActions ? (
          <div className="flex flex-wrap gap-2">
            {itTypeConfigs.length > 0 ? (
              <Button type="button" size="sm" variant="outline" onClick={() => setRegisterItOpen(true)}>
                <Stethoscope className="mr-1.5 h-4 w-4" />
                {t('absences.register_it_btn', 'Registrar IT')}
              </Button>
            ) : null}
            <Button type="button" size="sm" onClick={() => setRequestAbsenceOpen(true)}>
              <Plus className="mr-1.5 h-4 w-4" />
              {t('absences.employee_register_absence', 'Nova absència')}
            </Button>
          </div>
        ) : null}
      </div>

      {isLoading ? (
        <div className="flex items-center gap-2 py-6 text-sm text-muted-foreground">
          <Loader2 className="h-4 w-4 animate-spin" />
          {t('absences.loading', 'Carregant absències...')}
        </div>
      ) : absences.length === 0 ? (
        <p className="rounded-lg border border-dashed py-6 text-center text-sm text-muted-foreground">
          {t('absences.employee_panel_empty', 'Cap absència registrada per a aquest empleat.')}
        </p>
      ) : (
        <div className="space-y-2">
          {absences.slice(0, 8).map((absence) => (
            <EmployeeAbsenceRow
              key={absence.id}
              absence={absence}
              typeCfg={typeConfigMap[absence.absence_type ?? '']}
              lang={lang}
              isManager
            />
          ))}
          {absences.length > 8 ? (
            <p className="text-center text-xs text-muted-foreground">
              {t('absences.employee_panel_more', '+ {{count}} més al gestor global', {
                count: absences.length - 8,
              })}
            </p>
          ) : null}
        </div>
      )}

      <div className="flex justify-end">
        <Button type="button" variant="link" size="sm" className="h-auto p-0" asChild>
          <Link to={`/attendance-mgmt/absences?employeeId=${employeeId}`}>
            {t('absences.employee_panel_all_link', 'Veure totes les absències')}
            <ExternalLink className="ml-1 h-3.5 w-3.5" />
          </Link>
        </Button>
      </div>

      {!hideQuickActions ? (
        <RegisterITDialog
          open={registerItOpen}
          onOpenChange={setRegisterItOpen}
          employeeId={employeeId}
          employeeName={employeeName}
          itTypeConfigs={itTypeConfigs}
          lang={lang}
        />
      ) : null}

      {!hideQuickActions && requestAbsenceOpen ? (
        <RequestAbsenceDialog
          employeeId={employeeId}
          managerMode
          onClose={() => setRequestAbsenceOpen(false)}
        />
      ) : null}
    </div>
  )
}
