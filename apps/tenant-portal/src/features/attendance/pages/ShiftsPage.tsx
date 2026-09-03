import { useEffect, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useSearchParams } from 'react-router-dom'
import { AlertTriangle, ChevronLeft, ChevronRight, MapPin, Moon, Pencil, Plus, Send, Trash2 } from 'lucide-react'
import { useTenant } from '@/contexts/TenantContext'
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import {
  useWorkShifts,
  useSiteEmployees,
  useShiftSlots,
  useCoverageForPeriod,
  useAssignShiftSlot,
  useDeleteShiftSlots,
  usePublishShifts,
  usePreflightPublishShifts,
  useCreateWorkShift,
  useUpdateWorkShift,
  useDeactivateWorkShift,
} from '../api/useShifts'
import type { WorkShift, ShiftSlot, PreflightPublishResult, PreflightIssue } from '../api/shiftsService'
import { useWorkRoles } from '../api/useWorkRoles'
import { useFormatAttendanceDate } from '../hooks/useFormatAttendanceDate'
import {
  AssignmentContextInspector,
  type AssignmentInspectTarget,
} from '../components/AssignmentContextInspector'

type CoverageRowPosition = 'top' | 'bottom'
const COVERAGE_ROW_STORAGE_KEY = 'shifts-coverage-row-position'

function loadCoverageRowPosition(): CoverageRowPosition {
  try {
    return localStorage.getItem(COVERAGE_ROW_STORAGE_KEY) === 'top' ? 'top' : 'bottom'
  } catch {
    return 'bottom'
  }
}

type WorkShiftWithRole = WorkShift & { default_role_id?: string | null }

const COLOR_PRESETS = ['#6366f1', '#3b82f6', '#22c55e', '#f59e0b', '#ef4444', '#8b5cf6']

function getWeekStart(date: Date): Date {
  const d = new Date(date)
  const offset = (d.getDay() + 6) % 7
  d.setDate(d.getDate() - offset)
  d.setHours(0, 0, 0, 0)
  return d
}

function addDays(date: Date, n: number): Date {
  const d = new Date(date)
  d.setDate(d.getDate() + n)
  return d
}

/** Data local YYYY-MM-DD (evita desplaçament UTC de toISOString). */
function toISODate(d: Date) {
  const y = d.getFullYear()
  const m = String(d.getMonth() + 1).padStart(2, '0')
  const day = String(d.getDate()).padStart(2, '0')
  return `${y}-${m}-${day}`
}

function slotDurationMinutes(slot: ShiftSlot): number {
  if (!slot.start_time || !slot.end_time) return 0
  const [sh, sm] = slot.start_time.split(':').map(Number)
  const [eh, em] = slot.end_time.split(':').map(Number)
  const startMin = sh * 60 + sm
  const endMin = eh * 60 + em
  return slot.spans_midnight ? 24 * 60 - startMin + endMin : Math.max(0, endMin - startMin)
}

function timeInputValue(t: string | null | undefined): string {
  return (t ?? '09:00').slice(0, 5)
}

function warningLabel(code: string, t: (k: string, d: string) => string): string {
  switch (code) {
    case 'SHIFT_OVERLAP':
      return t('shifts.anomaly_overlap', 'Solapament de torns')
    case 'WEEKLY_HOURS_EXCEEDED':
      return t('shifts.anomaly_hours', 'Hores setmanals superades')
    case 'APPROVED_ABSENCE':
      return t('shifts.preflight_absence', 'Absència aprovada')
    case 'COVERAGE_SHORTAGE':
      return t('shifts.preflight_coverage', 'Cobertura insuficient')
    case 'NON_WORK_DAY':
      return t('shifts.preflight_non_work', 'Dia no laboral sense override')
    case 'PAYROLL_LOCKED':
      return t('shifts.preflight_payroll_locked', 'Dia bloquejat per nòmina')
    case 'MONTH_CLOSED':
      return t('shifts.preflight_month_closed', 'Mes tancat')
    default:
      return code
  }
}

function IssueList({
  title,
  issues,
  tone,
}: {
  title: string
  issues: PreflightIssue[]
  tone: 'block' | 'warn'
}) {
  const { t } = useTranslation('attendance')
  if (issues.length === 0) return null
  const cls =
    tone === 'block'
      ? 'border-destructive/40 bg-destructive/5 text-destructive'
      : 'border-amber-300 bg-amber-50 text-amber-900'
  return (
    <div className={`rounded-md border p-3 space-y-1.5 ${cls}`}>
      <p className="text-xs font-semibold uppercase tracking-wide">{title}</p>
      <ul className="space-y-1">
        {issues.map((issue, i) => (
          <li key={`${issue.code}-${issue.slot_id ?? ''}-${issue.work_date ?? ''}-${i}`} className="text-xs">
            <span className="font-medium">{warningLabel(issue.code, t)}</span>
            {issue.work_date ? ` · ${issue.work_date}` : ''}
            {issue.message ? ` — ${issue.message}` : ''}
          </li>
        ))}
      </ul>
    </div>
  )
}

interface PublishDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  weekStart: string
  draftCount: number
}

function PublishPreflightDialog({ open, onOpenChange, weekStart, draftCount }: PublishDialogProps) {
  const { t } = useTranslation('attendance')
  const formatDate = useFormatAttendanceDate()
  const preflight = usePreflightPublishShifts()
  const publish = usePublishShifts()
  const [result, setResult] = useState<PreflightPublishResult | null>(null)
  const [accepted, setAccepted] = useState<Record<string, boolean>>({})
  const [loadError, setLoadError] = useState<string | null>(null)

  useEffect(() => {
    if (!open) return
    setResult(null)
    setAccepted({})
    setLoadError(null)
    preflight.mutate(weekStart, {
      onSuccess: (data) => {
        setResult(data)
        const next: Record<string, boolean> = {}
        for (const code of data.required_warning_codes) next[code] = false
        setAccepted(next)
      },
      onError: (err: Error) => setLoadError(err.message),
    })
    // eslint-disable-next-line react-hooks/exhaustive-deps -- reload when dialog opens / week changes
  }, [open, weekStart])

  const requiredCodes = result?.required_warning_codes ?? []
  const allRequiredAccepted = requiredCodes.every((c) => accepted[c])
  const canConfirm =
    !!result &&
    result.can_publish &&
    result.draft_count > 0 &&
    allRequiredAccepted &&
    !publish.isPending

  const blockers = result?.blockers ?? []
  const warnings = result?.warnings ?? []
  const requireReason = warnings.filter((w) => w.severity === 'warn_require_reason')
  const infoWarns = warnings.filter((w) => w.severity !== 'warn_require_reason')

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>{t('shifts.preflight_title', 'Publicar setmana')}</DialogTitle>
        </DialogHeader>

        <div className="space-y-3 py-1">
          <p className="text-sm text-muted-foreground">
            {t('shifts.preflight_intro', '{{count}} esborranys a la setmana {{week}}', {
              count: result?.draft_count ?? draftCount,
              week: formatDate(weekStart),
            })}
          </p>

          {(preflight.isPending || (!result && !loadError)) && (
            <p className="text-sm text-muted-foreground">
              {t('shifts.preflight_loading', 'Validant publicació...')}
            </p>
          )}

          {loadError && (
            <div className="rounded-md border border-destructive/40 bg-destructive/5 p-3 text-xs text-destructive">
              {loadError}
            </div>
          )}

          {result && (
            <>
              <IssueList
                title={t('shifts.preflight_blockers', 'Bloquejos')}
                issues={blockers}
                tone="block"
              />
              <IssueList
                title={t('shifts.preflight_warnings', 'Avisos')}
                issues={[...requireReason, ...infoWarns]}
                tone="warn"
              />

              {requiredCodes.length > 0 && (
                <div className="space-y-2 rounded-md border border-border p-3">
                  <p className="text-xs font-medium">
                    {t(
                      'shifts.preflight_accept_required',
                      'Cal acceptar aquests avisos per publicar:',
                    )}
                  </p>
                  {requiredCodes.map((code) => (
                    <label key={code} className="flex items-start gap-2 text-xs cursor-pointer">
                      <input
                        type="checkbox"
                        className="mt-0.5"
                        checked={!!accepted[code]}
                        onChange={(e) =>
                          setAccepted((prev) => ({ ...prev, [code]: e.target.checked }))
                        }
                      />
                      <span>
                        {warningLabel(code, t)}
                        <span className="text-muted-foreground"> ({code})</span>
                      </span>
                    </label>
                  ))}
                </div>
              )}

              {blockers.length === 0 && warnings.length === 0 && (
                <p className="text-sm text-green-700">
                  {t('shifts.preflight_ok', 'Cap incidència. Pots publicar.')}
                </p>
              )}
            </>
          )}
        </div>

        <DialogFooter>
          <Button type="button" variant="ghost" onClick={() => onOpenChange(false)}>
            {t('shifts.template_cancel', 'Cancel·lar')}
          </Button>
          <Button
            type="button"
            disabled={!canConfirm}
            onClick={() => {
              const codes = requiredCodes.filter((c) => accepted[c])
              publish.mutate(
                { weekStart, warningsAccepted: codes },
                { onSuccess: () => onOpenChange(false) },
              )
            }}
          >
            {publish.isPending
              ? t('shifts.publishing', 'Publicant...')
              : t('shifts.preflight_confirm', 'Confirmar publicació')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

// ─── Template dialog ──────────────────────────────────────────────────────────

interface TemplateDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  initial?: WorkShiftWithRole | null
}

function WorkShiftTemplateDialog({ open, onOpenChange, initial }: TemplateDialogProps) {
  const { t } = useTranslation('attendance')
  const create = useCreateWorkShift()
  const update = useUpdateWorkShift()
  const deactivate = useDeactivateWorkShift()
  const { data: roles = [] } = useWorkRoles()

  const [name, setName] = useState(initial?.name ?? '')
  const [startTime, setStartTime] = useState(timeInputValue(initial?.start_time))
  const [endTime, setEndTime] = useState(timeInputValue(initial?.end_time))
  const [color, setColor] = useState(initial?.color ?? COLOR_PRESETS[0])
  const [defaultRoleId, setDefaultRoleId] = useState(initial?.default_role_id ?? '')

  const isEdit = !!initial?.id
  const busy = create.isPending || update.isPending || deactivate.isPending

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>
            {isEdit
              ? t('shifts.template_edit', 'Editar plantilla')
              : t('shifts.template_create', 'Nova plantilla')}
          </DialogTitle>
        </DialogHeader>
        <div className="grid gap-3 py-2">
          <div className="grid gap-1.5">
            <Label htmlFor="ws-name">{t('shifts.template_name', 'Nom')}</Label>
            <Input id="ws-name" value={name} onChange={(e) => setName(e.target.value)} />
          </div>
          <div className="grid grid-cols-2 gap-3">
            <div className="grid gap-1.5">
              <Label htmlFor="ws-start">{t('shifts.template_start', 'Inici')}</Label>
              <Input
                id="ws-start"
                type="time"
                value={startTime}
                onChange={(e) => setStartTime(e.target.value)}
              />
            </div>
            <div className="grid gap-1.5">
              <Label htmlFor="ws-end">{t('shifts.template_end', 'Final')}</Label>
              <Input
                id="ws-end"
                type="time"
                value={endTime}
                onChange={(e) => setEndTime(e.target.value)}
              />
            </div>
          </div>
          <div className="grid gap-1.5">
            <Label htmlFor="ws-role">{t('shifts.template_default_role', 'Rol per defecte')}</Label>
            <select
              id="ws-role"
              value={defaultRoleId}
              onChange={(e) => setDefaultRoleId(e.target.value)}
              className="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm"
            >
              <option value="">{t('shifts.template_no_role', 'Sense rol')}</option>
              {roles.map((r) => (
                <option key={r.id} value={r.id}>{r.name}</option>
              ))}
            </select>
          </div>
          <div className="grid gap-1.5">
            <Label>{t('shifts.template_color', 'Color')}</Label>
            <div className="flex flex-wrap gap-2">
              {COLOR_PRESETS.map((c) => (
                <button
                  key={c}
                  type="button"
                  onClick={() => setColor(c)}
                  className={[
                    'h-7 w-7 rounded-full border-2',
                    color === c ? 'border-foreground scale-110' : 'border-transparent',
                  ].join(' ')}
                  style={{ backgroundColor: c }}
                  aria-label={c}
                />
              ))}
            </div>
          </div>
        </div>
        <DialogFooter className="flex-col sm:flex-row gap-2">
          {isEdit && (
            <Button
              type="button"
              variant="outline"
              disabled={busy}
              className="sm:mr-auto text-destructive"
              onClick={() => {
                if (!initial?.id) return
                if (!window.confirm(t('shifts.template_deactivate_confirm', 'Desactivar aquesta plantilla?'))) return
                deactivate.mutate(initial.id, { onSuccess: () => onOpenChange(false) })
              }}
            >
              {t('shifts.template_deactivate', 'Desactivar')}
            </Button>
          )}
          <Button type="button" variant="ghost" onClick={() => onOpenChange(false)} disabled={busy}>
            {t('shifts.template_cancel', 'Cancel·lar')}
          </Button>
          <Button
            type="button"
            disabled={busy || !name.trim() || !startTime || !endTime || startTime === endTime}
            onClick={() => {
              if (isEdit && initial?.id) {
                update.mutate(
                  {
                    id: initial.id,
                    name: name.trim(),
                    start_time: startTime,
                    end_time: endTime,
                    color,
                    default_role_id: defaultRoleId || null,
                    clear_role: !defaultRoleId && !!initial.default_role_id,
                  },
                  { onSuccess: () => onOpenChange(false) },
                )
              } else {
                create.mutate(
                  {
                    name: name.trim(),
                    start_time: startTime,
                    end_time: endTime,
                    color,
                    default_role_id: defaultRoleId || null,
                  },
                  { onSuccess: () => onOpenChange(false) },
                )
              }
            }}
          >
            {t('shifts.template_save', 'Desar')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

// ─── Shift Palette ────────────────────────────────────────────────────────────

interface ShiftPaletteProps {
  shifts: WorkShift[]
  selected: WorkShift | null
  onSelect: (s: WorkShift | null) => void
  onCreate: () => void
  onEdit: (s: WorkShift) => void
}

function ShiftPalette({ shifts, selected, onSelect, onCreate, onEdit }: ShiftPaletteProps) {
  const { t } = useTranslation('attendance')
  return (
    <div className="flex flex-col gap-1">
      <div className="flex items-center justify-between mb-1">
        <p className="text-xs font-medium text-muted-foreground uppercase tracking-wide">
          {t('shifts.palette_title', 'Torns')}
        </p>
        <button
          type="button"
          onClick={onCreate}
          className="p-1 rounded hover:bg-accent text-muted-foreground hover:text-foreground"
          aria-label={t('shifts.template_create', 'Nova plantilla')}
          title={t('shifts.template_create', 'Nova plantilla')}
        >
          <Plus className="h-3.5 w-3.5" />
        </button>
      </div>
      {shifts.map((s) => (
        <div key={s.id} className="relative group">
          <button
            type="button"
            onClick={() => onSelect(selected?.id === s.id ? null : s)}
            className={[
              'flex w-full items-center gap-2 px-3 py-2 rounded-md text-xs text-left transition-all pr-8',
              selected?.id === s.id ? 'ring-2 ring-offset-1 ring-primary scale-105' : 'hover:opacity-80',
            ].join(' ')}
            style={{ backgroundColor: s.color ?? '#6366f1', color: '#fff' }}
            title={`${s.start_time} – ${s.end_time}`}
          >
            <span className="font-semibold truncate">{s.name}</span>
            <span className="opacity-80 ml-auto shrink-0">{s.start_time?.slice(0, 5)}</span>
          </button>
          <button
            type="button"
            onClick={(e) => {
              e.stopPropagation()
              onEdit(s)
            }}
            className="absolute top-1 right-1 p-1 rounded bg-black/25 opacity-0 group-hover:opacity-100 text-white"
            aria-label={t('shifts.template_edit', 'Editar plantilla')}
          >
            <Pencil className="h-3 w-3" />
          </button>
        </div>
      ))}
      {shifts.length === 0 && (
        <p className="text-xs text-muted-foreground">{t('shifts.no_shifts', 'Sense torns')}</p>
      )}
    </div>
  )
}

// ─── Planner Cell (multi-slot) ────────────────────────────────────────────────

interface PlannerCellProps {
  slots: ShiftSlot[]
  selectedShift: WorkShift | null
  employeeId: string
  date: string
  onAssign: (employeeId: string, shiftId: string, date: string) => void
  onDelete: (slotId: string) => void
  onInspect?: (employeeId: string, date: string) => void
  isAssigning: boolean
  isDeleting: boolean
}

function PlannerCell({
  slots,
  selectedShift,
  employeeId,
  date,
  onAssign,
  onDelete,
  onInspect,
  isAssigning,
  isDeleting,
}: PlannerCellProps) {
  const { t } = useTranslation('attendance')
  const alreadyHasSelected =
    !!selectedShift?.id && slots.some((s) => s.shift_id === selectedShift.id && s.status !== 'cancelled')

  return (
    <div className="min-h-14 flex flex-col gap-0.5">
      {slots.map((slot) => (
        <div
          key={slot.id}
          className="rounded-md flex flex-col items-center justify-center relative group text-white text-[10px] font-medium px-1 py-0.5"
          style={{ backgroundColor: slot.shift_color ?? '#6366f1' }}
        >
          <span className="truncate w-full text-center leading-tight">{slot.shift_name}</span>
          <span className="opacity-80 leading-tight">
            {slot.start_time?.slice(0, 5)}–{slot.end_time?.slice(0, 5)}
          </span>
          {slot.spans_midnight && (
            <span title={t('shifts.overnight', 'Torn nocturn (acaba el dia següent)')}>
              <Moon className="h-2.5 w-2.5 opacity-80" />
            </span>
          )}
          <button
            type="button"
            onClick={() => onDelete(slot.id ?? '')}
            disabled={isDeleting}
            className="absolute top-0 right-0 opacity-0 group-hover:opacity-100 transition-opacity bg-black/30 rounded p-0.5"
            aria-label={t('shifts.delete_slot', 'Eliminar torn')}
          >
            <Trash2 className="h-2.5 w-2.5" />
          </button>
        </div>
      ))}

      {selectedShift ? (
        <button
          type="button"
          onClick={() => onAssign(employeeId, selectedShift.id ?? '', date)}
          disabled={isAssigning || alreadyHasSelected}
          className="min-h-7 w-full rounded-md border-2 border-dashed flex items-center justify-center text-xs text-muted-foreground hover:border-primary hover:text-primary transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
          style={{ borderColor: selectedShift.color ?? undefined }}
          aria-label={
            alreadyHasSelected
              ? t('shifts.assign_already_present', 'Aquesta plantilla ja és en aquesta cel·la')
              : t('shifts.assign_slot', 'Assignar torn')
          }
          title={
            alreadyHasSelected
              ? t('shifts.assign_already_present', 'Aquesta plantilla ja és en aquesta cel·la')
              : undefined
          }
        >
          +
        </button>
      ) : slots.length === 0 ? (
        <button
          type="button"
          onClick={() => onInspect?.(employeeId, date)}
          className="h-full min-h-14 w-full rounded-md border border-dashed border-border/50 hover:border-primary/40 hover:bg-accent/30 transition-colors"
          aria-label={t('shifts.inspect_cell', 'Inspectar context')}
          title={t('shifts.inspect_cell', 'Inspectar context')}
        />
      ) : null}
    </div>
  )
}

function CoverageRow({
  weekDays,
  coverageByDate,
}: {
  weekDays: Date[]
  coverageByDate: Record<string, { employee_count: number; required_employee_count: number; coverage_delta: number }>
}) {
  const { t } = useTranslation('attendance')
  return (
    <div className="grid grid-cols-8 gap-1 items-center border-t border-border pt-2 bg-background">
      <div className="text-xs font-semibold text-muted-foreground pr-2 py-1 truncate">
        {t('shifts.coverage_label', 'Cobertura')}
      </div>
      {weekDays.map((d, i) => {
        const date = toISODate(d)
        const dayCoverage = coverageByDate[date]
        const assigned = dayCoverage?.employee_count ?? 0
        const required = dayCoverage?.required_employee_count ?? 0
        const delta = dayCoverage?.coverage_delta ?? assigned - required
        const statusClass =
          delta >= 0
            ? 'bg-green-50 text-green-700 border-green-200'
            : 'bg-red-50 text-red-700 border-red-200'

        return (
          <div
            key={i}
            className={`min-h-14 rounded-md border flex items-center justify-center text-xs font-semibold ${statusClass}`}
            title={t('shifts.coverage_delta', 'Diferència: {{delta}}', { delta })}
          >
            {t('shifts.coverage_value', '{{assigned}}/{{required}}', {
              assigned,
              required,
            })}
          </div>
        )
      })}
    </div>
  )
}

// ─── Main Page ────────────────────────────────────────────────────────────────

export function ShiftsPage() {
  const { t } = useTranslation('attendance')
  const formatDate = useFormatAttendanceDate()
  const { activeRole, selectedSiteId, setSelectedSiteId, sites } = useTenant()
  const isManager = activeRole === 'owner' || activeRole === 'manager'
  const [searchParams] = useSearchParams()

  const [weekStart, setWeekStart] = useState(() => {
    const weekParam = searchParams.get('week')
    if (weekParam && /^\d{4}-\d{2}-\d{2}$/.test(weekParam)) {
      const [y, m, d] = weekParam.split('-').map(Number)
      return getWeekStart(new Date(y, m - 1, d))
    }
    return getWeekStart(new Date())
  })
  const [selectedShift, setSelectedShift] = useState<WorkShift | null>(null)
  const [inspect, setInspect] = useState<AssignmentInspectTarget | null>(null)
  const [templateOpen, setTemplateOpen] = useState(false)
  const [editingTemplate, setEditingTemplate] = useState<WorkShiftWithRole | null>(null)
  const [coveragePosition, setCoveragePosition] = useState<CoverageRowPosition>(loadCoverageRowPosition)

  const setCoveragePositionPersist = (next: CoverageRowPosition) => {
    setCoveragePosition(next)
    try {
      localStorage.setItem(COVERAGE_ROW_STORAGE_KEY, next)
    } catch {
      /* ignore */
    }
  }

  const weekDays = useMemo(
    () => Array.from({ length: 7 }, (_, i) => addDays(weekStart, i)),
    [weekStart],
  )
  const from = toISODate(weekStart)
  const to = toISODate(weekDays[6])

  const { data: shifts = [] } = useWorkShifts()
  const { data: employees = [], isLoading: empLoading } = useSiteEmployees()
  const { data: slots = [], isLoading: slotsLoading } = useShiftSlots(from, to)
  const { data: coverage = [] } = useCoverageForPeriod(from, to)

  const { mutate: assign, isPending: isAssigning } = useAssignShiftSlot()
  const { mutate: deleteSlots, isPending: isDeleting } = useDeleteShiftSlots()
  const [publishOpen, setPublishOpen] = useState(false)

  const slotsMap = useMemo(() => {
    const map: Record<string, ShiftSlot[]> = {}
    for (const s of slots) {
      const key = `${s.employee_id}|${s.slot_date}`
      if (!map[key]) map[key] = []
      map[key].push(s)
    }
    for (const key of Object.keys(map)) {
      map[key].sort((a, b) => (a.start_time ?? '').localeCompare(b.start_time ?? ''))
    }
    return map
  }, [slots])

  const isLoading = empLoading || slotsLoading

  const coverageByDate = useMemo(() => {
    const map: Record<string, { employee_count: number; required_employee_count: number; coverage_delta: number }> = {}
    for (const day of coverage) {
      if (!day.work_date) continue
      map[day.work_date] = {
        employee_count: day.employee_count,
        required_employee_count: day.required_employee_count,
        coverage_delta: day.coverage_delta,
      }
    }
    return map
  }, [coverage])

  const weeklyHoursMap = useMemo(() => {
    const map: Record<string, number> = {}
    for (const s of slots) {
      if (!s.employee_id) continue
      map[s.employee_id] = (map[s.employee_id] ?? 0) + slotDurationMinutes(s)
    }
    return map
  }, [slots])

  const DAY_LABELS = [
    t('calendar.days.mon', 'Dl'),
    t('calendar.days.tue', 'Dt'),
    t('calendar.days.wed', 'Dc'),
    t('calendar.days.thu', 'Dj'),
    t('calendar.days.fri', 'Dv'),
    t('calendar.days.sat', 'Ds'),
    t('calendar.days.sun', 'Dg'),
  ]

  const draftCount = slots.filter((s) => s.status === 'draft').length

  if (!isManager) {
    return (
      <div className="p-4 text-center text-muted-foreground py-16">
        {t('shifts.no_permission', 'No tens permisos per accedir al planificador de torns')}
      </div>
    )
  }

  if (!selectedSiteId) {
    return (
      <div className="p-6">
        <div className="text-center text-muted-foreground mb-8">
          <p className="text-lg font-medium text-foreground">
            {t('shifts.no_site', 'Selecciona un centre per gestionar els torns')}
          </p>
          <p className="text-sm mt-1">
            {t('shifts.no_site_hint', 'Tria un dels centres disponibles')}
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
    <div className="flex h-full min-h-0 flex-col gap-3">
      <div className="flex shrink-0 flex-wrap items-center justify-between gap-3">
        <h1 className="text-2xl font-semibold">{t('shifts.title', 'Planificador de torns')}</h1>
        <div className="flex items-center gap-2">
          <button
            type="button"
            onClick={() => setWeekStart((w) => addDays(w, -7))}
            className="p-2 rounded-md hover:bg-accent"
            aria-label={t('shifts.prev_week', 'Setmana anterior')}
          >
            <ChevronLeft className="h-4 w-4" />
          </button>
          <span className="text-sm font-medium min-w-40 text-center">
            {formatDate(from)} – {formatDate(to)}
          </span>
          <button
            type="button"
            onClick={() => setWeekStart((w) => addDays(w, 7))}
            className="p-2 rounded-md hover:bg-accent"
            aria-label={t('shifts.next_week', 'Setmana següent')}
          >
            <ChevronRight className="h-4 w-4" />
          </button>
          <button
            type="button"
            onClick={() => setWeekStart(getWeekStart(new Date()))}
            className="px-3 py-1.5 text-xs rounded-md border hover:bg-accent"
          >
            {t('shifts.today', 'Avui')}
          </button>
          <select
            value={coveragePosition}
            onChange={(e) => setCoveragePositionPersist(e.target.value as CoverageRowPosition)}
            className="rounded-md border bg-background px-2 py-1.5 text-xs"
            aria-label={t('shifts.coverage_position', 'Posició de la fila de cobertura')}
            title={t('shifts.coverage_position', 'Posició de la fila de cobertura')}
          >
            <option value="bottom">{t('shifts.coverage_position_bottom', 'A baix (fixa)')}</option>
            <option value="top">{t('shifts.coverage_position_top', 'A dalt (fixa)')}</option>
          </select>
        </div>
        <button
          type="button"
          onClick={() => setPublishOpen(true)}
          disabled={draftCount === 0}
          className="flex items-center gap-2 px-4 py-2 rounded-md bg-primary text-primary-foreground text-sm hover:bg-primary/90 disabled:opacity-50"
        >
          <Send className="h-4 w-4" />
          {t('shifts.publish', 'Publicar setmana')}
          {draftCount > 0 && (
            <span className="bg-white/20 text-xs rounded-full px-1.5">{draftCount}</span>
          )}
        </button>
      </div>

      {isLoading ? (
        <div className="text-center py-12 text-muted-foreground">
          {t('shifts.loading', 'Carregant planificador...')}
        </div>
      ) : (
        <div className="flex min-h-0 flex-1 gap-4">
          <div className="w-44 shrink-0 overflow-y-auto">
            <ShiftPalette
              shifts={shifts}
              selected={selectedShift}
              onSelect={setSelectedShift}
              onCreate={() => {
                setEditingTemplate(null)
                setTemplateOpen(true)
              }}
              onEdit={(s) => {
                setEditingTemplate(s)
                setTemplateOpen(true)
              }}
            />
          </div>

          <div className="min-h-0 min-w-0 flex-1 overflow-auto">
            <div className="sticky top-0 z-20 bg-background pb-1">
              <div className="grid grid-cols-8 gap-1 mb-1">
                <div className="text-xs text-muted-foreground font-medium py-1">
                  {t('shifts.employee', 'Empleat/da')}
                </div>
                {weekDays.map((d, i) => (
                  <div key={i} className="text-center text-xs font-medium text-muted-foreground py-1">
                    <div>{DAY_LABELS[i]}</div>
                    <div>
                      {d.getDate()}/{d.getMonth() + 1}
                    </div>
                  </div>
                ))}
              </div>
              {coveragePosition === 'top' && employees.length > 0 && (
                <CoverageRow weekDays={weekDays} coverageByDate={coverageByDate} />
              )}
            </div>

            {employees.length === 0 ? (
              <div className="text-center py-8 text-muted-foreground text-sm border rounded-lg">
                {t('shifts.no_employees', 'No hi ha empleats en aquest centre')}
              </div>
            ) : (
              <div className="flex flex-col gap-1">
                {employees.map((emp) => (
                  <div key={emp.id} className="grid grid-cols-8 gap-1 items-start">
                    <div
                      className="text-xs font-medium pr-2 py-1 flex items-center gap-1 min-w-0"
                      title={
                        emp.weekly_hours != null &&
                        (weeklyHoursMap[emp.id ?? ''] ?? 0) > emp.weekly_hours * 60
                          ? t('shifts.hours_exceeded', 'Sobrepàs: {{assigned}}h / {{limit}}h', {
                              assigned: ((weeklyHoursMap[emp.id ?? ''] ?? 0) / 60).toFixed(1),
                              limit: emp.weekly_hours,
                            })
                          : (emp.full_name ?? '')
                      }
                    >
                      <button
                        type="button"
                        className="truncate text-left hover:underline hover:text-primary"
                        onClick={() =>
                          setInspect({
                            employeeId: emp.id ?? '',
                            date: toISODate(weekStart),
                          })
                        }
                      >
                        {emp.full_name}
                      </button>
                      {emp.weekly_hours != null &&
                        (weeklyHoursMap[emp.id ?? ''] ?? 0) > emp.weekly_hours * 60 && (
                          <AlertTriangle className="h-3 w-3 text-orange-500 shrink-0" />
                        )}
                    </div>
                    {weekDays.map((d, di) => {
                      const date = toISODate(d)
                      const daySlots = slotsMap[`${emp.id}|${date}`] ?? []
                      return (
                        <PlannerCell
                          key={di}
                          slots={daySlots}
                          selectedShift={selectedShift}
                          employeeId={emp.id ?? ''}
                          date={date}
                          onAssign={(eid, sid, dt) =>
                            assign({ employee_id: eid, shift_id: sid, slot_date: dt })
                          }
                          onDelete={(id) => deleteSlots([id])}
                          onInspect={(eid, dt) => setInspect({ employeeId: eid, date: dt })}
                          isAssigning={isAssigning}
                          isDeleting={isDeleting}
                        />
                      )
                    })}
                  </div>
                ))}

                {coveragePosition === 'bottom' && (
                  <div className="sticky bottom-0 z-10 bg-background shadow-[0_-6px_12px_-8px_rgba(0,0,0,0.25)]">
                    <CoverageRow weekDays={weekDays} coverageByDate={coverageByDate} />
                  </div>
                )}
              </div>
            )}
          </div>
        </div>
      )}

      {selectedShift && (
        <div
          className="fixed bottom-6 left-1/2 -translate-x-1/2 px-4 py-2 rounded-full text-white text-sm font-medium shadow-lg pointer-events-none"
          style={{ backgroundColor: selectedShift.color ?? '#6366f1' }}
        >
          {t('shifts.selected_hint', 'Fes clic a una cel·la per assignar: {{name}}', {
            name: selectedShift.name,
          })}
        </div>
      )}

      {templateOpen && (
        <WorkShiftTemplateDialog
          key={editingTemplate?.id ?? 'new'}
          open={templateOpen}
          onOpenChange={(open) => {
            setTemplateOpen(open)
            if (!open) setEditingTemplate(null)
          }}
          initial={editingTemplate}
        />
      )}

      {publishOpen && (
        <PublishPreflightDialog
          open={publishOpen}
          onOpenChange={setPublishOpen}
          weekStart={from}
          draftCount={draftCount}
        />
      )}

      {inspect && selectedSiteId ? (
        <AssignmentContextInspector
          open={!!inspect}
          onClose={() => setInspect(null)}
          employeeId={inspect.employeeId}
          siteId={selectedSiteId}
          workDate={inspect.date}
          startTime={inspect.startTime}
          endTime={inspect.endTime}
        />
      ) : null}
    </div>
  )
}
