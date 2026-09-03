import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Plus, Trash2 } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { useToast } from '@/hooks/use-toast'
import {
  useDeactivateAvailabilityException,
  useDeactivateAvailabilityRule,
  useEmployeeAvailabilityExceptions,
  useEmployeeAvailabilityRules,
  useUpsertAvailabilityException,
  useUpsertAvailabilityRule,
  type AvailabilityPreference,
} from '@/features/attendance/api/useEmployeeAvailability'

const DOW_LABELS = ['Diumenge', 'Dilluns', 'Dimarts', 'Dimecres', 'Dijous', 'Divendres', 'Dissabte']

function prefLabel(pref: string, t: (k: string, d: string) => string): string {
  switch (pref) {
    case 'preferred':
      return t('employees.avail_pref_preferred', 'Preferit')
    case 'unavailable':
      return t('employees.avail_pref_unavailable', 'No disponible')
    default:
      return t('employees.avail_pref_available', 'Disponible')
  }
}

export function EmployeeAvailabilitySection({
  employeeId,
  canWrite,
}: {
  employeeId: string
  canWrite: boolean
}) {
  const { t } = useTranslation('employees')
  const { toast } = useToast()
  const { data: rules = [], isLoading: loadingRules } = useEmployeeAvailabilityRules(employeeId)
  const { data: exceptions = [], isLoading: loadingExc } = useEmployeeAvailabilityExceptions(employeeId)
  const upsertRule = useUpsertAvailabilityRule()
  const removeRule = useDeactivateAvailabilityRule()
  const upsertExc = useUpsertAvailabilityException()
  const removeExc = useDeactivateAvailabilityException()

  const [dow, setDow] = useState(1)
  const [start, setStart] = useState('09:00')
  const [end, setEnd] = useState('17:00')
  const [pref, setPref] = useState<AvailabilityPreference>('available')

  const [excDate, setExcDate] = useState('')
  const [excPref, setExcPref] = useState<AvailabilityPreference>('unavailable')
  const [excAllDay, setExcAllDay] = useState(true)
  const [excStart, setExcStart] = useState('09:00')
  const [excEnd, setExcEnd] = useState('17:00')
  const [excNotes, setExcNotes] = useState('')

  async function addRule() {
    try {
      await upsertRule.mutateAsync({
        employee_id: employeeId,
        day_of_week: dow,
        start_time: start,
        end_time: end,
        preference: pref,
      })
      toast({ title: t('employees.avail_rule_added', 'Regla afegida') })
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('employees.avail_error', 'No s\'ha pogut desar'),
        description: err instanceof Error ? err.message : String(err),
      })
    }
  }

  async function addException() {
    if (!excDate) return
    try {
      await upsertExc.mutateAsync({
        employee_id: employeeId,
        exception_date: excDate,
        preference: excPref,
        all_day: excAllDay,
        start_time: excAllDay ? null : excStart,
        end_time: excAllDay ? null : excEnd,
        notes: excNotes || null,
      })
      setExcDate('')
      setExcNotes('')
      toast({ title: t('employees.avail_exc_added', 'Excepció afegida') })
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('employees.avail_error', 'No s\'ha pogut desar'),
        description: err instanceof Error ? err.message : String(err),
      })
    }
  }

  return (
    <div className="space-y-6 rounded-lg border p-4">
      <div>
        <h3 className="text-sm font-semibold">
          {t('employees.avail_title', 'Disponibilitat')}
        </h3>
        <p className="mt-1 text-xs text-muted-foreground">
          {t(
            'employees.avail_hint',
            'Preferències recurrents i excepcions. No és una absència ni garanteix un torn; serveix per suggerir i filtrar vacants.',
          )}
        </p>
      </div>

      <div>
        <h4 className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
          {t('employees.avail_rules', 'Regles setmanals')}
        </h4>
        {loadingRules ? (
          <p className="mt-2 text-xs text-muted-foreground">{t('common.loading', 'Carregant…')}</p>
        ) : (
          <ul className="mt-2 space-y-1">
            {rules.map((r) => (
              <li key={r.id} className="flex items-center justify-between text-sm">
                <span>
                  {DOW_LABELS[r.day_of_week] ?? r.day_of_week}
                  {' '}
                  <span className="tabular-nums">{r.start_time}–{r.end_time}</span>
                  <span className="ml-2 text-xs text-muted-foreground">
                    {prefLabel(r.preference, t)}
                  </span>
                </span>
                {canWrite ? (
                  <Button
                    type="button"
                    size="icon"
                    variant="ghost"
                    className="h-7 w-7"
                    onClick={() => void removeRule.mutateAsync({ id: r.id, employee_id: employeeId })}
                  >
                    <Trash2 className="h-3.5 w-3.5 text-destructive" />
                  </Button>
                ) : null}
              </li>
            ))}
            {rules.length === 0 ? (
              <li className="text-xs text-muted-foreground">
                {t('employees.avail_rules_empty', 'Sense regles')}
              </li>
            ) : null}
          </ul>
        )}
        {canWrite ? (
          <div className="mt-2 grid grid-cols-2 gap-2 sm:grid-cols-5">
            <select
              value={dow}
              onChange={(e) => setDow(Number(e.target.value))}
              className="rounded-md border border-input bg-background px-2 py-1.5 text-sm"
            >
              {DOW_LABELS.map((label, i) => (
                <option key={label} value={i}>
                  {label}
                </option>
              ))}
            </select>
            <input
              type="time"
              value={start}
              onChange={(e) => setStart(e.target.value)}
              className="rounded-md border border-input bg-background px-2 py-1.5 text-sm"
            />
            <input
              type="time"
              value={end}
              onChange={(e) => setEnd(e.target.value)}
              className="rounded-md border border-input bg-background px-2 py-1.5 text-sm"
            />
            <select
              value={pref}
              onChange={(e) => setPref(e.target.value as AvailabilityPreference)}
              className="rounded-md border border-input bg-background px-2 py-1.5 text-sm"
            >
              <option value="preferred">{prefLabel('preferred', t)}</option>
              <option value="available">{prefLabel('available', t)}</option>
              <option value="unavailable">{prefLabel('unavailable', t)}</option>
            </select>
            <Button type="button" size="sm" onClick={() => void addRule()}>
              <Plus className="h-3.5 w-3.5" />
            </Button>
          </div>
        ) : null}
      </div>

      <div>
        <h4 className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
          {t('employees.avail_exceptions', 'Excepcions')}
        </h4>
        {loadingExc ? (
          <p className="mt-2 text-xs text-muted-foreground">{t('common.loading', 'Carregant…')}</p>
        ) : (
          <ul className="mt-2 space-y-1">
            {exceptions.map((x) => (
              <li key={x.id} className="flex items-center justify-between text-sm">
                <span>
                  <span className="tabular-nums">{x.exception_date}</span>
                  {' '}
                  {x.start_time && x.end_time ? (
                    <span className="tabular-nums">{x.start_time}–{x.end_time}</span>
                  ) : (
                    <span className="text-xs text-muted-foreground">
                      {t('employees.avail_all_day', 'tot el dia')}
                    </span>
                  )}
                  <span className="ml-2 text-xs text-muted-foreground">
                    {prefLabel(x.preference, t)}
                  </span>
                </span>
                {canWrite ? (
                  <Button
                    type="button"
                    size="icon"
                    variant="ghost"
                    className="h-7 w-7"
                    onClick={() => void removeExc.mutateAsync({ id: x.id, employee_id: employeeId })}
                  >
                    <Trash2 className="h-3.5 w-3.5 text-destructive" />
                  </Button>
                ) : null}
              </li>
            ))}
            {exceptions.length === 0 ? (
              <li className="text-xs text-muted-foreground">
                {t('employees.avail_exc_empty', 'Sense excepcions properes')}
              </li>
            ) : null}
          </ul>
        )}
        {canWrite ? (
          <div className="mt-2 space-y-2">
            <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
              <input
                type="date"
                value={excDate}
                onChange={(e) => setExcDate(e.target.value)}
                className="rounded-md border border-input bg-background px-2 py-1.5 text-sm"
              />
              <select
                value={excPref}
                onChange={(e) => setExcPref(e.target.value as AvailabilityPreference)}
                className="rounded-md border border-input bg-background px-2 py-1.5 text-sm"
              >
                <option value="unavailable">{prefLabel('unavailable', t)}</option>
                <option value="available">{prefLabel('available', t)}</option>
                <option value="preferred">{prefLabel('preferred', t)}</option>
              </select>
              <label className="flex items-center gap-2 text-xs">
                <input
                  type="checkbox"
                  checked={excAllDay}
                  onChange={(e) => setExcAllDay(e.target.checked)}
                />
                {t('employees.avail_all_day', 'tot el dia')}
              </label>
              <Button type="button" size="sm" onClick={() => void addException()} disabled={!excDate}>
                <Plus className="h-3.5 w-3.5" />
              </Button>
            </div>
            {!excAllDay ? (
              <div className="flex gap-2">
                <input
                  type="time"
                  value={excStart}
                  onChange={(e) => setExcStart(e.target.value)}
                  className="rounded-md border border-input bg-background px-2 py-1.5 text-sm"
                />
                <input
                  type="time"
                  value={excEnd}
                  onChange={(e) => setExcEnd(e.target.value)}
                  className="rounded-md border border-input bg-background px-2 py-1.5 text-sm"
                />
              </div>
            ) : null}
            <input
              value={excNotes}
              onChange={(e) => setExcNotes(e.target.value)}
              placeholder={t('employees.avail_notes', 'Motiu (opcional)')}
              className="w-full rounded-md border border-input bg-background px-2 py-1.5 text-sm"
            />
          </div>
        ) : null}
      </div>
    </div>
  )
}
