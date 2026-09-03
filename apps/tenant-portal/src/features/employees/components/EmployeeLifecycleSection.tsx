import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Loader2 } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { useToast } from '@/hooks/use-toast'
import { useEmployeePermissions } from '../hooks/useEmployeePermissions'
import {
  useEmployeeLifecycleEvents,
  useLifecycleTransitionRules,
  useTransitionEmployeeLifecycle,
} from '../api/useEmployeeLifecycle'
import { EmployeeAssetReturnChecklistPanel } from './EmployeeAssetReturnChecklistPanel'
import { usePermission } from '@/hooks/usePermission'

const STATE_KEYS = [
  'candidate',
  'onboarding',
  'active',
  'on_leave',
  'departure',
  'offboarding',
  'terminated',
] as const

export function EmployeeLifecycleSection({
  employeeId,
  lifecycleState,
  siteId,
}: {
  employeeId: string
  lifecycleState: string | null | undefined
  siteId?: string | null
}) {
  const { t } = useTranslation('employees')
  const { toast } = useToast()
  const perms = useEmployeePermissions(siteId ? { site_id: siteId } : null)

  const { data: events = [], isLoading, error } = useEmployeeLifecycleEvents(
    perms.canViewLifecycle ? employeeId : undefined,
  )
  const { data: rules = [] } = useLifecycleTransitionRules()
  const transition = useTransitionEmployeeLifecycle()
  const canManageAssets =
    usePermission('assets.employee_assignments.manage') || perms.canManageLifecycle

  const [toState, setToState] = useState('')
  const [reasonCode, setReasonCode] = useState('')
  const [effectiveOn, setEffectiveOn] = useState(() => new Date().toISOString().slice(0, 10))

  const currentState = lifecycleState ?? 'active'

  const availableTransitions = useMemo(
    () => rules.filter((r) => r.from_state === currentState),
    [rules, currentState],
  )

  const selectedRule = availableTransitions.find((r) => r.to_state === toState)
  const reasonOptions = selectedRule?.auto_reason_codes ?? []

  if (!perms.canViewLifecycle) {
    return null
  }

  async function handleTransition() {
    if (!toState || !reasonCode) {
      toast({
        variant: 'destructive',
        title: t('employees.lifecycle.required', 'Selecciona estat i motiu'),
      })
      return
    }
    try {
      await transition.mutateAsync({
        employee_id: employeeId,
        to_state: toState,
        reason_code: reasonCode,
        effective_on: effectiveOn || undefined,
      })
      const isFuture = effectiveOn > new Date().toISOString().slice(0, 10)
      toast({
        title: isFuture
          ? t('employees.lifecycle.scheduled', 'Transició programada')
          : t('employees.lifecycle.transitioned', 'Estat actualitzat'),
      })
      setToState('')
      setReasonCode('')
      setEffectiveOn(new Date().toISOString().slice(0, 10))
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('employees.lifecycle.transition_failed', "No s'ha pogut canviar l'estat"),
        description: err instanceof Error ? err.message : undefined,
      })
    }
  }

  function stateLabel(state: string) {
    return t(`employees.lifecycle.states.${state}`, state)
  }

  return (
    <div className="space-y-4 rounded-lg border p-4">
      <div>
        <h2 className="text-base font-semibold">
          {t('employees.lifecycle.title', 'Cicle de vida')}
        </h2>
        <p className="text-sm text-muted-foreground mt-1">
          {t('employees.lifecycle.current', 'Estat actual')}:{' '}
          <span className="font-medium text-foreground">{stateLabel(currentState)}</span>
        </p>
      </div>

      {perms.canManageLifecycle && availableTransitions.length > 0 ? (
        <div className="flex flex-wrap items-end gap-2">
          <div className="min-w-[10rem]">
            <label className="text-xs font-medium text-muted-foreground">
              {t('employees.lifecycle.to_state', 'Nou estat')}
            </label>
            <select
              className="mt-1 w-full rounded-md border bg-background px-3 py-2 text-sm"
              value={toState}
              onChange={(e) => {
                setToState(e.target.value)
                setReasonCode('')
              }}
            >
              <option value="">{t('employees.lifecycle.select', 'Selecciona…')}</option>
              {availableTransitions.map((r) => (
                <option key={r.to_state} value={r.to_state}>
                  {stateLabel(r.to_state)}
                </option>
              ))}
            </select>
          </div>
          <div className="min-w-[12rem]">
            <label className="text-xs font-medium text-muted-foreground">
              {t('employees.lifecycle.reason', 'Motiu')}
            </label>
            <select
              className="mt-1 w-full rounded-md border bg-background px-3 py-2 text-sm"
              value={reasonCode}
              onChange={(e) => setReasonCode(e.target.value)}
              disabled={!toState}
            >
              <option value="">{t('employees.lifecycle.select', 'Selecciona…')}</option>
              {reasonOptions.map((code) => (
                <option key={code} value={code}>
                  {t(`employees.lifecycle.reasons.${code}`, code)}
                </option>
              ))}
            </select>
          </div>
          <div className="min-w-[10rem]">
            <label className="text-xs font-medium text-muted-foreground">
              {t('employees.lifecycle.effective_on', 'Data efectiva')}
            </label>
            <input
              type="date"
              className="mt-1 w-full rounded-md border bg-background px-3 py-2 text-sm"
              value={effectiveOn}
              onChange={(e) => setEffectiveOn(e.target.value)}
            />
          </div>
          <Button disabled={transition.isPending || !toState || !reasonCode} onClick={() => void handleTransition()}>
            {transition.isPending ? <Loader2 className="h-4 w-4 animate-spin" /> : t('employees.lifecycle.apply', 'Aplicar')}
          </Button>
        </div>
      ) : null}

      {['departure', 'offboarding', 'terminated'].includes(currentState) ? (
        <EmployeeAssetReturnChecklistPanel
          employeeId={employeeId}
          canManage={canManageAssets}
        />
      ) : null}

      {isLoading ? (
        <div className="flex justify-center py-4">
          <div className="animate-spin rounded-full h-6 w-6 border-b-2 border-primary" />
        </div>
      ) : error ? (
        <p className="text-sm text-red-600">
          {t('employees.lifecycle.load_failed', "No s'ha pogut carregar l'historial")}
        </p>
      ) : (
        <div className="overflow-x-auto rounded-xl border">
          <table className="min-w-full text-sm">
            <thead className="bg-muted/50 text-left">
              <tr>
                <th className="px-3 py-2 font-medium">{t('employees.lifecycle.col_when', 'Data')}</th>
                <th className="px-3 py-2 font-medium">{t('employees.lifecycle.col_from', 'De')}</th>
                <th className="px-3 py-2 font-medium">{t('employees.lifecycle.col_to', 'A')}</th>
                <th className="px-3 py-2 font-medium">{t('employees.lifecycle.col_reason', 'Motiu')}</th>
                <th className="px-3 py-2 font-medium">{t('employees.lifecycle.col_source', 'Origen')}</th>
              </tr>
            </thead>
            <tbody>
              {events.length === 0 ? (
                <tr>
                  <td colSpan={5} className="px-3 py-4 text-center text-muted-foreground">
                    {t('employees.lifecycle.empty', 'Sense historial')}
                  </td>
                </tr>
              ) : (
                events.map((ev) => {
                  const scheduled =
                    (ev.metadata as { scheduled?: boolean } | null)?.scheduled === true &&
                    ev.reason_code !== 'scheduled_transition_applied'
                  return (
                  <tr key={ev.id} className="border-t">
                    <td className="px-3 py-2">
                      {ev.effective_on}
                      {scheduled ? (
                        <span className="ml-1 text-[10px] uppercase tracking-wide text-amber-700">
                          {t('employees.lifecycle.pending', 'programat')}
                        </span>
                      ) : null}
                    </td>
                    <td className="px-3 py-2">{ev.from_state ? stateLabel(ev.from_state) : '—'}</td>
                    <td className="px-3 py-2">{stateLabel(ev.to_state)}</td>
                    <td className="px-3 py-2">
                      {t(`employees.lifecycle.reasons.${ev.reason_code}`, ev.reason_code)}
                    </td>
                    <td className="px-3 py-2">{ev.source}</td>
                  </tr>
                  )
                })
              )}
            </tbody>
          </table>
        </div>
      )}

      {/* Keep STATE_KEYS referenced for i18n discovery */}
      <span className="hidden">{STATE_KEYS.join(',')}</span>
    </div>
  )
}
