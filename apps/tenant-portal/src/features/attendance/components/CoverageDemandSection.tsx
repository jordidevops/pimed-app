import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Info, MapPin, Plus, Pencil, Check, X, Trash2 } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { useWorkRoles } from '../api/useWorkRoles'
import {
  useCoverageDemands,
  useDeactivateCoverageDemand,
  useUpsertCoverageDemand,
  type CoverageDemand,
  type CoverageDemandKind,
} from '../api/useCoverageDemands'
import { useFormatAttendanceDate } from '../hooks/useFormatAttendanceDate'
import { CoverageBucketsPanel } from './CoverageBucketsPanel'
import {
  CoverageDemandPeriodPanel,
  buildDemandRulesSummary,
} from './CoverageDemandPeriodPanel'

const DOW_KEYS = [
  'sunday',
  'monday',
  'tuesday',
  'wednesday',
  'thursday',
  'friday',
  'saturday',
] as const

function todayISO(): string {
  const d = new Date()
  const y = d.getFullYear()
  const m = String(d.getMonth() + 1).padStart(2, '0')
  const day = String(d.getDate()).padStart(2, '0')
  return `${y}-${m}-${day}`
}

function timeInputValue(raw: string | null | undefined): string {
  if (!raw) return ''
  return raw.length >= 5 ? raw.slice(0, 5) : raw
}

function formatValidity(
  d: CoverageDemand,
  formatDate: (iso: string) => string,
  t: (key: string, fallback: string, opts?: Record<string, unknown>) => string,
): string {
  const from = d.effective_from?.slice(0, 10)
  const to = d.effective_to?.slice(0, 10)
  if (from && to) {
    return t('planificacio.demand_validity_range', '{{from}} – {{to}}', {
      from: formatDate(from),
      to: formatDate(to),
    })
  }
  if (from && !to) {
    return t('planificacio.demand_validity_from', 'Des de {{date}}', {
      date: formatDate(from),
    })
  }
  if (!from && to) {
    return t('planificacio.demand_validity_until', 'Fins a {{date}}', {
      date: formatDate(to),
    })
  }
  return t('planificacio.demand_validity_open', 'Sense límit de vigència')
}

export function CoverageDemandSection() {
  const { t } = useTranslation('attendance')
  const formatDate = useFormatAttendanceDate()
  const { toast } = useToast()
  const { selectedSiteId, setSelectedSiteId, sites } = useTenant()
  const { data: demands = [], isLoading, isError, error, refetch } = useCoverageDemands()
  const { data: roles = [] } = useWorkRoles()
  const upsert = useUpsertCoverageDemand()
  const deactivate = useDeactivateCoverageDemand()

  const [selectedDate, setSelectedDate] = useState(todayISO)
  const [editing, setEditing] = useState<CoverageDemand | null>(null)
  const [creating, setCreating] = useState(false)
  const [kind, setKind] = useState<CoverageDemandKind>('recurring')
  const [name, setName] = useState('')
  const [dayOfWeek, setDayOfWeek] = useState(1)
  const [demandDate, setDemandDate] = useState('')
  const [startTime, setStartTime] = useState('09:00')
  const [endTime, setEndTime] = useState('17:00')
  const [target, setTarget] = useState('2')
  const [roleId, setRoleId] = useState('')

  const dowLabels = useMemo(
    () => ({
      sunday: t('planificacio.demand_dow_sun', 'Diumenge'),
      monday: t('planificacio.demand_dow_mon', 'Dilluns'),
      tuesday: t('planificacio.demand_dow_tue', 'Dimarts'),
      wednesday: t('planificacio.demand_dow_wed', 'Dimecres'),
      thursday: t('planificacio.demand_dow_thu', 'Dijous'),
      friday: t('planificacio.demand_dow_fri', 'Divendres'),
      saturday: t('planificacio.demand_dow_sat', 'Dissabte'),
    }),
    [t],
  )

  const dowShort = useMemo(
    () => [
      t('calendar.days.sun', 'Dg'),
      t('calendar.days.mon', 'Dl'),
      t('calendar.days.tue', 'Dt'),
      t('calendar.days.wed', 'Dc'),
      t('calendar.days.thu', 'Dj'),
      t('calendar.days.fri', 'Dv'),
      t('calendar.days.sat', 'Ds'),
    ],
    [t],
  )

  const rulesSummary = useMemo(
    () => buildDemandRulesSummary(demands, selectedDate, dowShort, t),
    [demands, selectedDate, dowShort, t],
  )

  function resetForm() {
    setCreating(false)
    setEditing(null)
    setKind('recurring')
    setName('')
    setDayOfWeek(1)
    setDemandDate('')
    setStartTime('09:00')
    setEndTime('17:00')
    setTarget('2')
    setRoleId('')
  }

  function startCreate() {
    resetForm()
    setCreating(true)
  }

  function startEdit(row: CoverageDemand) {
    setCreating(false)
    setEditing(row)
    setKind(row.kind)
    setName(row.name ?? '')
    setDayOfWeek(row.day_of_week ?? 1)
    setDemandDate(row.demand_date ?? '')
    setStartTime(timeInputValue(row.start_time))
    setEndTime(timeInputValue(row.end_time))
    setTarget(String(row.required_target))
    setRoleId(row.role_id ?? '')
  }

  async function save() {
    if (!selectedSiteId) {
      toast({
        variant: 'destructive',
        title: t('planificacio.demand_need_site', 'Selecciona un centre'),
      })
      return
    }
    const requiredTarget = Number(target)
    if (!Number.isFinite(requiredTarget) || requiredTarget < 0) return
    if (startTime === endTime) {
      toast({
        variant: 'destructive',
        title: t('planificacio.demand_invalid_times', 'L\'hora d\'inici i final han de ser diferents'),
      })
      return
    }
    try {
      await upsert.mutateAsync({
        id: editing?.id,
        site_id: selectedSiteId,
        kind,
        day_of_week: kind === 'recurring' ? dayOfWeek : null,
        demand_date: kind === 'extraordinary' ? demandDate : null,
        start_time: startTime,
        end_time: endTime,
        required_target: requiredTarget,
        required_min: 0,
        role_id: roleId || null,
        clear_role: !roleId && !!editing?.role_id,
        name: name.trim() || null,
      })
      toast({ title: t('planificacio.demand_saved', 'Demanda desada') })
      resetForm()
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('planificacio.demand_save_error', 'No s\'ha pogut desar'),
        description: err instanceof Error ? err.message : String(err),
      })
    }
  }

  if (!selectedSiteId) {
    return (
      <div className="p-6">
        <div className="text-center text-muted-foreground mb-8">
          <p className="text-lg font-medium text-foreground">
            {t('planificacio.demand_need_site', 'Selecciona un centre per gestionar la demanda de cobertura')}
          </p>
          <p className="text-sm mt-1">
            {t('planificacio.demand_need_site_hint', 'Tria un dels centres disponibles')}
          </p>
        </div>
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3 max-w-2xl mx-auto">
          {sites.map((site) => (
            <button
              key={site.id}
              type="button"
              onClick={() => setSelectedSiteId(site.id)}
              className="flex items-center gap-3 p-4 rounded-lg border border-border hover:border-primary hover:bg-accent transition-colors text-left"
            >
              <MapPin className="h-5 w-5 text-muted-foreground shrink-0" />
              <span className="font-medium">{site.name}</span>
            </button>
          ))}
        </div>
      </div>
    )
  }

  return (
    <div className="space-y-4">
      <CoverageDemandPeriodPanel
        selectedDate={selectedDate}
        onSelectDate={setSelectedDate}
        demands={demands}
      />

      <CoverageBucketsPanel date={selectedDate} onDateChange={setSelectedDate} />

      <div className="flex items-start gap-2 rounded-lg border border-sky-200 bg-sky-50 px-4 py-3 text-sm text-sky-950 dark:border-sky-800 dark:bg-sky-950/30 dark:text-sky-100">
        <Info className="mt-0.5 h-4 w-4 shrink-0" />
        <p>
          {t(
            'planificacio.demand_help',
            'Defineix quantes persones calen per franja (recurrent o dia concret), opcionalment per rol. No assigna torns: només marca la demanda per detectar gaps.',
          )}
        </p>
      </div>

      <div className="flex items-center justify-between gap-2">
        <div className="min-w-0">
          <h3 className="text-sm font-semibold">
            {t('planificacio.demand_title', 'Demanda de cobertura')}
          </h3>
          {demands.length > 0 && (
            <p className="text-xs text-muted-foreground truncate">{rulesSummary}</p>
          )}
        </div>
        {!creating && !editing ? (
          <Button type="button" size="sm" variant="outline" onClick={startCreate}>
            <Plus className="mr-1 h-3.5 w-3.5" />
            {t('planificacio.demand_add', 'Afegir demanda')}
          </Button>
        ) : null}
      </div>

      {(creating || editing) && (
        <div className="space-y-2 rounded-lg border p-3">
          <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
            <div>
              <label className="mb-0.5 block text-xs font-medium">
                {t('planificacio.demand_kind', 'Tipus')}
              </label>
              <select
                value={kind}
                onChange={(e) => setKind(e.target.value as CoverageDemandKind)}
                className="w-full rounded border bg-background px-2 py-1 text-xs"
              >
                <option value="recurring">{t('planificacio.demand_kind_recurring', 'Recurrent')}</option>
                <option value="extraordinary">{t('planificacio.demand_kind_extra', 'Extraordinària')}</option>
              </select>
            </div>
            {kind === 'recurring' ? (
              <div>
                <label className="mb-0.5 block text-xs font-medium">
                  {t('planificacio.demand_dow', 'Dia')}
                </label>
                <select
                  value={dayOfWeek}
                  onChange={(e) => setDayOfWeek(Number(e.target.value))}
                  className="w-full rounded border bg-background px-2 py-1 text-xs"
                >
                  {DOW_KEYS.map((key, i) => (
                    <option key={key} value={i}>{dowLabels[key]}</option>
                  ))}
                </select>
              </div>
            ) : (
              <div>
                <label className="mb-0.5 block text-xs font-medium">
                  {t('planificacio.demand_date', 'Data')}
                </label>
                <input
                  type="date"
                  value={demandDate}
                  onChange={(e) => setDemandDate(e.target.value)}
                  className="w-full rounded border bg-background px-2 py-1 text-xs"
                />
              </div>
            )}
            <div>
              <label className="mb-0.5 block text-xs font-medium">
                {t('planificacio.demand_start', 'Inici')}
              </label>
              <input
                type="time"
                value={startTime}
                onChange={(e) => setStartTime(e.target.value)}
                className="w-full rounded border bg-background px-2 py-1 text-xs"
              />
            </div>
            <div>
              <label className="mb-0.5 block text-xs font-medium">
                {t('planificacio.demand_end', 'Final')}
              </label>
              <input
                type="time"
                value={endTime}
                onChange={(e) => setEndTime(e.target.value)}
                className="w-full rounded border bg-background px-2 py-1 text-xs"
              />
            </div>
          </div>
          <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
            <div>
              <label className="mb-0.5 block text-xs font-medium">
                {t('planificacio.demand_target', 'Persones (objectiu)')}
              </label>
              <input
                type="number"
                min={0}
                value={target}
                onChange={(e) => setTarget(e.target.value)}
                className="w-full rounded border bg-background px-2 py-1 text-xs"
              />
            </div>
            <div>
              <label className="mb-0.5 block text-xs font-medium">
                {t('planificacio.demand_role', 'Rol')}
              </label>
              <select
                value={roleId}
                onChange={(e) => setRoleId(e.target.value)}
                className="w-full rounded border bg-background px-2 py-1 text-xs"
              >
                <option value="">{t('planificacio.demand_role_any', 'Qualsevol')}</option>
                {roles.map((r) => (
                  <option key={r.id} value={r.id}>{r.name}</option>
                ))}
              </select>
            </div>
            <div className="sm:col-span-2">
              <label className="mb-0.5 block text-xs font-medium">
                {t('planificacio.demand_name', 'Nom (opcional)')}
              </label>
              <input
                value={name}
                onChange={(e) => setName(e.target.value)}
                className="w-full rounded border bg-background px-2 py-1 text-xs"
                placeholder={t('planificacio.demand_name_ph', 'Ex. Punta dinar')}
              />
            </div>
          </div>
          <div className="flex gap-2">
            <Button
              type="button"
              size="sm"
              onClick={() => void save()}
              disabled={
                upsert.isPending
                || !startTime
                || !endTime
                || (kind === 'extraordinary' && !demandDate)
              }
            >
              <Check className="mr-1 h-3.5 w-3.5" />
              {t('common.save', 'Desar')}
            </Button>
            <Button type="button" size="sm" variant="ghost" onClick={resetForm}>
              <X className="mr-1 h-3.5 w-3.5" />
              {t('common.cancel', 'Cancel·lar')}
            </Button>
          </div>
        </div>
      )}

      {isLoading ? (
        <p className="text-sm text-muted-foreground">{t('common.loading', 'Carregant…')}</p>
      ) : isError ? (
        <div className="rounded-lg border border-destructive/40 bg-destructive/5 px-3 py-2 text-sm">
          <p className="text-destructive">
            {t('planificacio.demand_load_error', 'No s\'ha pogut carregar la demanda')}
          </p>
          <p className="mt-1 text-xs text-muted-foreground">
            {error instanceof Error ? error.message : String(error)}
          </p>
          <Button type="button" size="sm" variant="outline" className="mt-2" onClick={() => void refetch()}>
            {t('common.retry', 'Tornar a provar')}
          </Button>
        </div>
      ) : demands.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          {t('planificacio.demand_empty', 'Encara no hi ha demanda definida per aquest centre.')}
        </p>
      ) : (
        <ul className="divide-y rounded-lg border">
          {demands.map((d) => (
            <li key={d.id} className="flex items-center justify-between gap-2 px-3 py-2 text-sm">
              <div className="min-w-0 flex-1">
                <div className="font-medium">
                  {d.name || (d.kind === 'recurring'
                    ? dowLabels[DOW_KEYS[d.day_of_week ?? 0]]
                    : d.demand_date)}
                  <span className="ml-2 text-xs font-normal text-muted-foreground">
                    {timeInputValue(d.start_time)}–{timeInputValue(d.end_time)}
                  </span>
                </div>
                <div className="text-xs text-muted-foreground">
                  {d.kind === 'recurring'
                    ? t('planificacio.demand_kind_recurring', 'Recurrent')
                    : t('planificacio.demand_kind_extra', 'Extraordinària')}
                  {' · '}
                  {t('planificacio.demand_target_short', '{{n}} persones', { n: d.required_target })}
                  {d.role_name ? ` · ${d.role_name}` : ''}
                  {' · '}
                  {formatValidity(d, formatDate, t)}
                </div>
              </div>
              <div className="flex gap-1">
                <Button type="button" size="icon" variant="ghost" className="h-7 w-7" onClick={() => startEdit(d)}>
                  <Pencil className="h-3.5 w-3.5" />
                </Button>
                <Button
                  type="button"
                  size="icon"
                  variant="ghost"
                  className="h-7 w-7"
                  onClick={() => void deactivate.mutateAsync(d.id)}
                >
                  <Trash2 className="h-3.5 w-3.5 text-destructive" />
                </Button>
              </div>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
