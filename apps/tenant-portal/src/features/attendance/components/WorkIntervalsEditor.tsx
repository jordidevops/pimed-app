import { Plus, Trash2 } from 'lucide-react'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import type { WorkInterval } from '../api/workIntervals'
import { validateWorkIntervals } from '../api/workIntervals'

interface WorkIntervalsEditorProps {
  intervals: WorkInterval[]
  onChange: (intervals: WorkInterval[]) => void
  compact?: boolean
}

export function WorkIntervalsEditor({ intervals, onChange, compact = false }: WorkIntervalsEditorProps) {
  const { t } = useTranslation('attendance')
  const errorKey = validateWorkIntervals(intervals)

  function update(idx: number, field: 'start' | 'end', value: string) {
    const next = intervals.map((iv, i) => (i === idx ? { ...iv, [field]: value } : iv))
    onChange(next)
  }

  function addSlot() {
    const last = intervals[intervals.length - 1]
    const start = last ? last.end : '09:00'
    onChange([...intervals, { start, end: '17:00' }])
  }

  function removeSlot(idx: number) {
    if (intervals.length <= 1) return
    onChange(intervals.filter((_, i) => i !== idx))
  }

  return (
    <div className={`space-y-2 ${compact ? '' : 'w-full'}`}>
      <div className="flex flex-wrap items-center gap-2">
        <span className="text-xs text-muted-foreground shrink-0">
          {t('labor_cal.hours', 'Horari')}
        </span>
        <span className="text-[10px] text-muted-foreground">
          {t('labor_cal.overnight_hint', 'Si la sortida és anterior a l\'entrada, s\'entén dia següent (+1).')}
        </span>
      </div>
      {intervals.map((iv, idx) => (
        <div key={idx} className="flex flex-wrap items-center gap-1.5">
          <input
            type="time"
            value={iv.start}
            onChange={(e) => update(idx, 'start', e.target.value)}
            className="border rounded px-2 py-1 text-xs bg-background w-[6.5rem]"
            aria-label={t('labor_cal.interval_start', 'Inici franja {{n}}', { n: idx + 1 })}
          />
          <span className="text-xs text-muted-foreground">–</span>
          <input
            type="time"
            value={iv.end}
            onChange={(e) => update(idx, 'end', e.target.value)}
            className="border rounded px-2 py-1 text-xs bg-background w-[6.5rem]"
            aria-label={t('labor_cal.interval_end', 'Fi franja {{n}}', { n: idx + 1 })}
          />
          {intervals.length > 1 && (
            <button
              type="button"
              onClick={() => removeSlot(idx)}
              className="p-1 rounded hover:bg-destructive/10 text-muted-foreground hover:text-destructive"
              title={t('labor_cal.remove_interval', 'Eliminar franja')}
            >
              <Trash2 className="h-3.5 w-3.5" />
            </button>
          )}
        </div>
      ))}
      <Button type="button" variant="outline" size="sm" className="h-7 text-xs gap-1" onClick={addSlot}>
        <Plus className="h-3.5 w-3.5" />
        {t('labor_cal.add_interval', 'Afegir franja')}
      </Button>
      {errorKey === 'interval_overlap' && (
        <p className="text-xs text-destructive">
          {t('labor_cal.interval_overlap', 'Les franges no es poden solapar. Cada entrada ha de ser posterior a la sortida anterior.')}
        </p>
      )}
    </div>
  )
}
