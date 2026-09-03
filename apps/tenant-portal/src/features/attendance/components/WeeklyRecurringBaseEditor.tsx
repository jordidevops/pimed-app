import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Pencil, Check, X, Loader2, RotateCcw } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { WorkIntervalsEditor } from './WorkIntervalsEditor'
import { defaultIntervals, formatIntervalsList, validateWorkIntervals, type WorkInterval } from '../api/workIntervals'
import {
  useCalendarGroupWeeklyPattern,
  useSetCalendarGroupWeeklyDay,
  useClearCalendarGroupWeeklyDay,
  useEmployeeWeeklyPattern,
  useSetEmployeeWeeklyDay,
  useClearEmployeeWeeklyDay,
} from '../api/useShifts'
import type { WeeklyDayPattern } from '../api/shiftsService'

/**
 * ADR-0003: editor de la base recurrent setmanal (per grup de calendari o per
 * empleat). Escriu directament a `calendar_group_weekly_intervals` /
 * `employee_weekly_intervals` — no materialitza files a `labor_calendar_overrides`.
 */

// Postgres EXTRACT(DOW): 0=diumenge … 6=dissabte. Mostrem dilluns primer.
const DOW_MON_FIRST = [1, 2, 3, 4, 5, 6, 0] as const

interface WeeklyRecurringBaseEditorProps {
  mode: 'group' | 'employee'
  entityId: string
}

export function WeeklyRecurringBaseEditor({ mode, entityId }: WeeklyRecurringBaseEditorProps) {
  const { t } = useTranslation('attendance')
  const dowLabels = t('labor_cal.dow_full', { returnObjects: true }) as string[]

  const groupQuery = useCalendarGroupWeeklyPattern(mode === 'group' ? entityId : null)
  const employeeQuery = useEmployeeWeeklyPattern(mode === 'employee' ? entityId : null)
  const { data: pattern, isLoading } = mode === 'group' ? groupQuery : employeeQuery

  const { mutate: setGroupDay, isPending: settingGroupDay } = useSetCalendarGroupWeeklyDay()
  const { mutate: clearGroupDay, isPending: clearingGroupDay } = useClearCalendarGroupWeeklyDay()
  const { mutate: setEmployeeDay, isPending: settingEmployeeDay } = useSetEmployeeWeeklyDay()
  const { mutate: clearEmployeeDay, isPending: clearingEmployeeDay } = useClearEmployeeWeeklyDay()

  const isSaving = mode === 'group' ? settingGroupDay : settingEmployeeDay
  const isClearing = mode === 'group' ? clearingGroupDay : clearingEmployeeDay

  const byDow = new Map<number, WeeklyDayPattern>((pattern ?? []).map((p) => [p.day_of_week, p]))

  function saveDay(dow: number, dayType: 'work' | 'non_working', intervals: WorkInterval[]) {
    const payload = {
      dayOfWeek: dow,
      dayType,
      workIntervals: dayType === 'work' ? intervals : null,
    }
    if (mode === 'group') {
      setGroupDay({ groupId: entityId, ...payload })
    } else {
      setEmployeeDay({ employeeId: entityId, ...payload })
    }
  }

  function clearDay(dow: number) {
    if (mode === 'group') {
      clearGroupDay({ groupId: entityId, dayOfWeek: dow })
    } else {
      clearEmployeeDay({ employeeId: entityId, dayOfWeek: dow })
    }
  }

  if (isLoading) {
    return (
      <p className="text-xs text-muted-foreground flex items-center gap-1.5">
        <Loader2 className="h-3.5 w-3.5 animate-spin" />
        {t('weekly_base.loading', 'Carregant patró setmanal…')}
      </p>
    )
  }

  return (
    <div className="rounded-lg border divide-y">
      {DOW_MON_FIRST.map((dow) => (
        <WeeklyDayRow
          key={dow}
          dow={dow}
          label={dowLabels[(dow + 6) % 7] ?? String(dow)}
          existing={byDow.get(dow) ?? null}
          onSave={(dayType, intervals) => saveDay(dow, dayType, intervals)}
          onClear={() => clearDay(dow)}
          isSaving={isSaving}
          isClearing={isClearing}
        />
      ))}
    </div>
  )
}

function WeeklyDayRow({
  dow, label, existing, onSave, onClear, isSaving, isClearing,
}: {
  dow: number
  label: string
  existing: WeeklyDayPattern | null
  onSave: (dayType: 'work' | 'non_working', intervals: WorkInterval[]) => void
  onClear: () => void
  isSaving: boolean
  isClearing: boolean
}) {
  const { t } = useTranslation('attendance')
  const [editing, setEditing] = useState(false)
  const [dayType, setDayType] = useState<'work' | 'non_working'>(existing?.day_type ?? 'work')
  const [intervals, setIntervals] = useState<WorkInterval[]>(
    existing?.work_intervals?.length ? existing.work_intervals : defaultIntervals(),
  )

  useEffect(() => {
    if (editing) return
    setDayType(existing?.day_type ?? 'work')
    setIntervals(existing?.work_intervals?.length ? existing.work_intervals : defaultIntervals())
  }, [existing, editing])

  const intervalError = dayType === 'work' ? validateWorkIntervals(intervals) : null

  function handleSave() {
    if (intervalError) return
    onSave(dayType, intervals)
    setEditing(false)
  }

  return (
    <div className="px-3 py-2.5">
      <div className="flex items-center gap-3">
        <span className="text-sm font-medium w-24 shrink-0">{label}</span>

        {!editing ? (
          <>
            <div className="flex-1 min-w-0">
              {existing ? (
                existing.day_type === 'work' ? (
                  <span className="text-xs text-muted-foreground">
                    {formatIntervalsList(existing.work_intervals)}
                  </span>
                ) : (
                  <span className="inline-flex items-center rounded-full bg-muted px-2 py-0.5 text-xs font-medium text-muted-foreground">
                    {t('weekly_base.non_working', 'No laborable')}
                  </span>
                )
              ) : (
                <span className="text-xs text-muted-foreground italic">
                  {t('weekly_base.no_pattern', 'Sense patró definit')}
                </span>
              )}
            </div>
            <button
              type="button"
              className="text-muted-foreground hover:text-foreground shrink-0 p-1 rounded"
              onClick={() => setEditing(true)}
              title={t('weekly_base.edit_day', 'Editar dia')}
            >
              <Pencil className="h-3.5 w-3.5" />
            </button>
            {existing && (
              <button
                type="button"
                className="text-muted-foreground hover:text-destructive shrink-0 p-1 rounded"
                onClick={onClear}
                disabled={isClearing}
                title={t('weekly_base.clear_day', 'Eliminar patró (sense definir)')}
              >
                <RotateCcw className="h-3.5 w-3.5" />
              </button>
            )}
          </>
        ) : (
          <div className="flex-1 min-w-0" />
        )}
      </div>

      {editing && (
        <div className="mt-2 space-y-2 pl-1">
          <div className="flex flex-wrap gap-1.5">
            {(['work', 'non_working'] as const).map((type) => (
              <button
                key={type}
                type="button"
                onClick={() => setDayType(type)}
                className={`px-2.5 py-0.5 rounded-full text-xs font-medium transition-colors ${
                  type === 'work'
                    ? 'bg-emerald-100 text-emerald-800 dark:bg-emerald-900/40 dark:text-emerald-200'
                    : 'bg-muted text-muted-foreground'
                } ${dayType === type ? 'ring-2 ring-offset-1 ring-foreground/40' : 'opacity-60'}`}
              >
                {type === 'work'
                  ? t('weekly_base.work', 'Laborable')
                  : t('weekly_base.non_working', 'No laborable')}
              </button>
            ))}
          </div>
          {dayType === 'work' && <WorkIntervalsEditor intervals={intervals} onChange={setIntervals} compact />}
          <div className="flex justify-end gap-2">
            <Button variant="outline" size="sm" className="h-7 text-xs" onClick={() => setEditing(false)}>
              <X className="h-3.5 w-3.5" />
            </Button>
            <Button size="sm" className="h-7 text-xs gap-1" disabled={isSaving || !!intervalError} onClick={handleSave}>
              <Check className="h-3.5 w-3.5" />
              {t('weekly_base.save_day', 'Desar')}
            </Button>
          </div>
        </div>
      )}
    </div>
  )
}
