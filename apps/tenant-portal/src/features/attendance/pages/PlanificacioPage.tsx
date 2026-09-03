import { useState, useEffect, useMemo } from 'react'
import { useTranslation } from 'react-i18next'
import { useSearchParams } from 'react-router-dom'
import { Info, Plus, Pencil, Check, X, Users, Trash2, ChevronDown, ChevronUp, CalendarClock } from 'lucide-react'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { supabase } from '@/lib/supabase'
import { useToast } from '@/hooks/use-toast'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { LaborCalendarGrid } from '../components/LaborCalendarGrid'
import { LaborCalendarSetupPage } from './LaborCalendarSetupPage'
import { PauseConfigSection } from '../components/PauseConfigSection'
import { WorkRolesSection } from '../components/WorkRolesSection'
import { CoverageDemandSection } from '../components/CoverageDemandSection'
import { PlanningHeuristicsSection } from '../components/PlanningHeuristicsSection'
import { WeeklyRecurringBaseEditor } from '../components/WeeklyRecurringBaseEditor'
import { useCalendarGroups, useUpsertCalendarGroup, useDeleteCalendarGroup, listCalendarGroupEmployees, type CalendarGroup, type CalendarGroupEmployee, sanitizeOptionalUuid } from '../api/useLaborCalendar'
import { AttendanceGeoEnabledField } from '../components/AttendanceGeoEnabledField'
import { AttendancePunchOnlyAtStationsField } from '../components/AttendancePunchOnlyAtStationsField'
import { AttendanceRecordPolicyEditor } from '../components/settings/AttendanceRecordPolicyEditor'
import {
  fromAttendanceGeoEnabledFormValue,
  toAttendanceGeoEnabledFormValue,
  type AttendanceGeoEnabledFormValue,
} from '../utils/attendanceGeoFormUtils'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useTenant } from '@/contexts/TenantContext'

export function PlanificacioPage() {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const [searchParams, setSearchParams] = useSearchParams()
  const tabFromUrl = searchParams.get('tab')
  const allowedTabs = useMemo(
    () => new Set(['visual-calendar', 'groups', 'holidays', 'pauses', 'roles', 'demand', 'heuristics', 'config']),
    [],
  )
  const activeTab = tabFromUrl && allowedTabs.has(tabFromUrl) ? tabFromUrl : 'visual-calendar'

  return (
    <Tabs
      value={activeTab}
      onValueChange={(value) => {
        const next = new URLSearchParams(searchParams)
        if (value === 'visual-calendar') next.delete('tab')
        else next.set('tab', value)
        setSearchParams(next, { replace: true })
      }}
    >
      <TabsList>
        <TabsTrigger value="visual-calendar">
          {t('planificacio.tab_visual_calendar', 'Calendari')}
        </TabsTrigger>
        <TabsTrigger value="groups">
          {t('planificacio.tab_groups', 'Grups')}
        </TabsTrigger>
        <TabsTrigger value="holidays">
          {t('planificacio.tab_holidays_setup', 'Festius')}
        </TabsTrigger>
        <TabsTrigger value="pauses">
          {t('planificacio.tab_pauses', 'Tipus de pausa')}
        </TabsTrigger>
        <TabsTrigger value="roles">
          {t('planificacio.tab_roles', 'Rols')}
        </TabsTrigger>
        <TabsTrigger value="demand">
          {t('planificacio.tab_demand', 'Demanda')}
        </TabsTrigger>
        <TabsTrigger value="heuristics">
          {t('planificacio.tab_heuristics', 'Heurístiques')}
        </TabsTrigger>
        <TabsTrigger value="config">
          {t('planificacio.tab_config', 'Configuració')}
        </TabsTrigger>
      </TabsList>

      <TabsContent value="visual-calendar" className="mt-4">
        <LaborCalendarGrid />
      </TabsContent>

      <TabsContent value="groups" className="mt-4">
        <CalendarGroupsSection />
      </TabsContent>

      <TabsContent value="holidays" className="mt-4 space-y-4">
        <div className="flex items-start gap-2 rounded-lg border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900 dark:bg-amber-950/30 dark:border-amber-800 dark:text-amber-100">
          <Info className="mt-0.5 h-4 w-4 shrink-0" />
          <p>
            {t(
              'planificacio.holidays_reference_help',
              'Importeu i assigneu calendaris de festius oficials. Els festius assignats es mostren al calendari visual; podeu sobreescriure\'ls editant dies a la pestanya «Calendari».',
            )}
          </p>
        </div>
        <LaborCalendarSetupPage onlyTab="holidays" alwaysShowHolidays holidaysOnly />
      </TabsContent>

      <TabsContent value="pauses" className="mt-4">
        <PauseConfigSection />
      </TabsContent>

      <TabsContent value="roles" className="mt-4">
        <WorkRolesSection />
      </TabsContent>

      <TabsContent value="demand" className="mt-4">
        <CoverageDemandSection />
      </TabsContent>

      <TabsContent value="heuristics" className="mt-4">
        <PlanningHeuristicsSection />
      </TabsContent>

      <TabsContent value="config" className="mt-4 space-y-8">
        <VacationEntitlementsSection t={t} queryClient={queryClient} toast={toast} />
      </TabsContent>
    </Tabs>
  )
}

// ─── Vacation Entitlements Section ───────────────────────────────────────────

interface EntitlementRow {
  id: string
  year: number
  scope: string
  leave_type: string
  days_allocated: number
  days_used: number
  days_remaining: number
}

function VacationEntitlementsSection({
  t, queryClient, toast,
}: {
  t: ReturnType<typeof useTranslation>['t']
  queryClient: ReturnType<typeof useQueryClient>
  toast: ReturnType<typeof useToast>['toast']
}) {
  const currentYear = new Date().getFullYear()
  const [entYear, setEntYear] = useState(currentYear)
  const [entDays, setEntDays] = useState('22')
  const [saving, setSaving] = useState(false)

  const { data: entitlementsList, refetch } = useQuery({
    queryKey: ['attendance', 'vacation-entitlements-list'],
    queryFn: async (): Promise<EntitlementRow[]> => {
      const { data, error } = await supabase.rpc(
        'list_tenant_vacation_entitlements' as never,
      )
      if (error) throw error
      return (data as EntitlementRow[]) ?? []
    },
    staleTime: 30_000,
  })

  const currentYearRow = entitlementsList?.find(r => r.year === currentYear)
  const hasCurrentYear = !!currentYearRow

  async function saveEntitlement() {
    setSaving(true)
    const { error } = await (supabase.rpc as unknown as (name: string, args: object) => Promise<{ error: { message: string } | null }>)(
      'upsert_vacation_entitlement',
      { p_scope: 'tenant', p_year: entYear, p_leave_type: 'vacation', p_days_allocated: Number(entDays) },
    )
    setSaving(false)
    if (error) {
      toast({ variant: 'destructive', title: error.message })
      return
    }
    toast({ title: t('planificacio.entitlement_saved', 'Dies de vacances desats') })
    queryClient.invalidateQueries({ queryKey: ['attendance'] })
    refetch()
  }

  return (
    <section className="max-w-lg">
      <h3 className="mb-1 text-sm font-semibold">
        {t('planificacio.tab_entitlements', 'Dies de vacances globals (empresa)')}
      </h3>
      <p className="text-xs text-muted-foreground mb-4">
        {t('planificacio.entitlements_help',
          'Definiu el nombre de dies de vacances que corresponen a tots els empleats per defecte (el treballador pot tenir un acord individual diferent).')}
      </p>

      {/* Avís si l'any actual no té configuració */}
      {!hasCurrentYear && entitlementsList !== undefined && (
        <div className="flex items-start gap-2 rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-900 mb-4">
          <Info className="mt-0.5 h-3.5 w-3.5 shrink-0" />
          <span>
            {t('planificacio.no_entitlement_current_year',
              `L'any ${currentYear} no té dies de vacances configurats. Els empleats apareixeran amb 0 dies disponibles fins que ho configureu.`)}
          </span>
        </div>
      )}

      {/* Llista d'anys configurats */}
      {entitlementsList && entitlementsList.length > 0 && (
        <div className="rounded-lg border divide-y mb-4">
          {entitlementsList.map(row => (
            <div key={row.id} className="flex items-center gap-3 px-3 py-2 text-sm">
              <span className="font-semibold w-12 shrink-0">{row.year}</span>
              <div className="flex-1 flex gap-3 text-xs">
                <span className="text-muted-foreground">
                  {t('planificacio.days_allocated_short', 'Assignats')}:{' '}
                  <span className="font-medium text-foreground">{row.days_allocated}</span>
                </span>
                <span className="text-muted-foreground">
                  {t('planificacio.days_used_short', 'Usats')}:{' '}
                  <span className={`font-medium ${row.days_used > 0 ? 'text-amber-700' : 'text-foreground'}`}>
                    {row.days_used}
                  </span>
                </span>
                <span className="text-muted-foreground">
                  {t('planificacio.days_remaining_short', 'Restants')}:{' '}
                  <span className={`font-medium ${row.days_remaining === 0 ? 'text-red-600' : 'text-green-700'}`}>
                    {row.days_remaining}
                  </span>
                </span>
              </div>
              <button
                type="button"
                className="text-xs text-muted-foreground hover:text-foreground"
                onClick={() => { setEntYear(row.year); setEntDays(row.days_allocated.toString()) }}
              >
                {t('planificacio.edit', 'Editar')}
              </button>
            </div>
          ))}
        </div>
      )}

      {/* Formulari d'assignació */}
      <div className="rounded-lg border p-4 space-y-3 bg-muted/30">
        <p className="text-xs font-medium">
          {t('planificacio.assign_year_entitlement', 'Assignar dies per any')}
        </p>
        <div className="grid grid-cols-2 gap-3">
          <div className="space-y-1.5">
            <Label htmlFor="ent-year" className="text-xs">{t('planificacio.year', 'Any')}</Label>
            <Input id="ent-year" type="number" value={entYear}
              onChange={e => setEntYear(Number(e.target.value))} className="h-8 text-sm" />
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="ent-days" className="text-xs">
              {t('planificacio.days_allocated', 'Dies hàbils de vacances')}
            </Label>
            <Input id="ent-days" type="number" min="0" value={entDays}
              onChange={e => setEntDays(e.target.value)} className="h-8 text-sm" />
          </div>
        </div>
        <Button size="sm" disabled={saving} onClick={saveEntitlement} className="w-full">
          {saving
            ? t('planificacio.saving', 'Desant...')
            : t('planificacio.save_entitlement', 'Desar dies de vacances')}
        </Button>
      </div>
    </section>
  )
}

// ─── Calendar Groups Section ──────────────────────────────────────────────────

const COLOR_PRESETS = [
  '#6366f1', '#0ea5e9', '#10b981', '#f59e0b',
  '#ef4444', '#8b5cf6', '#ec4899', '#64748b',
]

interface GroupFormState {
  name: string
  color: string
  description: string
  scope: 'global' | 'site'
  siteId: string
  attendance_geo_enabled: AttendanceGeoEnabledFormValue
  punch_only_at_stations: AttendanceGeoEnabledFormValue
}
const emptyGroupForm = (): GroupFormState => ({
  name: '',
  color: '#6366f1',
  description: '',
  scope: 'global',
  siteId: '',
  attendance_geo_enabled: 'inherit',
  punch_only_at_stations: 'inherit',
})

function DeleteCalendarGroupDialog({
  group,
  groups,
  open,
  onOpenChange,
  onDeleted,
}: {
  group: CalendarGroup
  groups: CalendarGroup[]
  open: boolean
  onOpenChange: (open: boolean) => void
  onDeleted: () => void
}) {
  const { t } = useTranslation('attendance')
  const { mutate: deleteGroup, isPending } = useDeleteCalendarGroup()
  const [members, setMembers] = useState<CalendarGroupEmployee[]>([])
  const [loadingMembers, setLoadingMembers] = useState(false)
  const [reassignId, setReassignId] = useState<string>('')

  const otherGroups = groups.filter((g) => g.id !== group.id)

  useEffect(() => {
    if (!open) return
    setReassignId('')
    setLoadingMembers(true)
    listCalendarGroupEmployees(group.id)
      .then(setMembers)
      .finally(() => setLoadingMembers(false))
  }, [open, group.id])

  function handleDelete() {
    deleteGroup(
      {
        groupId: group.id,
        reassignToGroupId: members.length > 0 && reassignId ? reassignId : null,
      },
      {
        onSuccess: () => {
          onOpenChange(false)
          onDeleted()
        },
      },
    )
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>{t('cal_groups.delete_title', 'Eliminar grup «{{name}}»?', { name: group.name })}</DialogTitle>
          <DialogDescription>
            {loadingMembers
              ? t('cal_groups.delete_loading', 'Comprovant empleats assignats…')
              : members.length === 0
                ? t('cal_groups.delete_no_members', 'Cap empleat té aquest grup assignat. Els overrides del grup s\'eliminaran.')
                : t('cal_groups.delete_has_members', '{{count}} empleat(s) tenen aquest grup. Trieu què fer abans d\'eliminar-lo.', { count: members.length })}
          </DialogDescription>
        </DialogHeader>

        {members.length > 0 && !loadingMembers && (
          <div className="space-y-3 text-sm">
            <ul className="max-h-32 overflow-y-auto rounded-md border divide-y text-xs">
              {members.map((m) => (
                <li key={m.employee_id} className="px-3 py-2 truncate">{m.full_name ?? m.employee_id}</li>
              ))}
            </ul>
            <div className="space-y-1.5">
              <Label className="text-xs">{t('cal_groups.delete_reassign_label', 'Reassignar empleats a')}</Label>
              <select
                value={reassignId}
                onChange={(e) => setReassignId(e.target.value)}
                className="w-full border rounded-md h-9 px-2 text-sm bg-background"
              >
                <option value="">{t('cal_groups.delete_reassign_none', 'Treure el grup (sense reassignar)')}</option>
                {otherGroups.map((g) => (
                  <option key={g.id} value={g.id}>{g.name}</option>
                ))}
              </select>
              {otherGroups.length === 0 && (
                <p className="text-[11px] text-muted-foreground">
                  {t('cal_groups.delete_no_other_groups', 'No hi ha altres grups. Els empleats quedaran sense grup assignat.')}
                </p>
              )}
            </div>
          </div>
        )}

        <DialogFooter className="gap-2 sm:gap-0">
          <Button variant="outline" onClick={() => onOpenChange(false)} disabled={isPending}>
            {t('cal_groups.cancel', 'Cancel·lar')}
          </Button>
          <Button variant="destructive" onClick={handleDelete} disabled={isPending || loadingMembers}>
            {isPending ? t('cal_groups.deleting', 'Eliminant…') : t('cal_groups.delete_confirm', 'Eliminar grup')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

// ─── Group Weekly Base (ADR-0003) ────────────────────────────────────────────

function GroupWeeklyBaseSection({ groupId }: { groupId: string }) {
  const { t } = useTranslation('attendance')
  const [open, setOpen] = useState(false)

  return (
    <div className="rounded-lg border">
      <button
        type="button"
        className="w-full flex items-center justify-between gap-2 px-3 py-2.5 text-left"
        onClick={() => setOpen((o) => !o)}
      >
        <span className="flex items-center gap-2 text-sm font-semibold">
          <CalendarClock className="h-4 w-4" />
          {t('weekly_base.group_title', 'Patró setmanal recurrent')}
        </span>
        {open ? <ChevronUp className="h-4 w-4 shrink-0" /> : <ChevronDown className="h-4 w-4 shrink-0" />}
      </button>
      {open && (
        <div className="px-3 pb-3 space-y-3">
          <p className="text-[11px] text-muted-foreground">
            {t(
              'weekly_base.group_hint',
              'Horari habitual del grup, consultat en viu (no crea files per dia). Els empleats poden tenir un override individual i els overrides puntuals de dies concrets sempre tenen prioritat.',
            )}
          </p>
          <WeeklyRecurringBaseEditor mode="group" entityId={groupId} />
        </div>
      )}
    </div>
  )
}

function CalendarGroupsSection() {
  const { t } = useTranslation('attendance')
  const { sites } = useTenant()
  const { data: groups = [], isLoading } = useCalendarGroups(null)
  const { mutate: upsert, isPending } = useUpsertCalendarGroup()
  const [selected, setSelected] = useState<CalendarGroup | null>(null)
  const [showForm, setShowForm] = useState(false)
  const [editingId, setEditingId] = useState<string | null>(null)
  const [form, setForm] = useState<GroupFormState>(emptyGroupForm)
  const [editScope, setEditScope] = useState<'global' | 'site'>('global')
  const [editSiteId, setEditSiteId] = useState<string | null>(null)
  const [deleteTarget, setDeleteTarget] = useState<CalendarGroup | null>(null)

  function openNew() {
    setEditingId(null)
    setForm(emptyGroupForm())
    setShowForm(true)
  }

  function openEdit(g: CalendarGroup) {
    setEditingId(g.id)
    setForm({
      name: g.name,
      color: g.color,
      description: g.description ?? '',
      scope: g.site_id ? 'site' : 'global',
      siteId: g.site_id ?? '',
      attendance_geo_enabled: toAttendanceGeoEnabledFormValue(g.attendance_geo_enabled),
      punch_only_at_stations: toAttendanceGeoEnabledFormValue(g.punch_only_at_stations),
    })
    setShowForm(true)
  }

  function selectGroup(g: CalendarGroup | null) {
    setSelected(g)
    if (!g) return
    if (g.site_id) {
      setEditScope('site')
      setEditSiteId(g.site_id)
    } else {
      setEditScope('global')
      setEditSiteId(sites[0]?.id ?? null)
    }
  }

  function handleSave() {
    const siteId = form.scope === 'site' ? sanitizeOptionalUuid(form.siteId) : null
    if (form.scope === 'site' && !siteId) return
    upsert({
      id: editingId ?? undefined,
      name: form.name.trim(),
      color: form.color,
      description: form.description.trim() || undefined,
      siteId,
      attendanceGeoEnabled: fromAttendanceGeoEnabledFormValue(form.attendance_geo_enabled),
      punchOnlyAtStations: fromAttendanceGeoEnabledFormValue(form.punch_only_at_stations),
    }, {
      onSuccess: () => {
        setShowForm(false)
        setEditingId(null)
      },
    })
  }

  const isSiteBoundGroup = !!selected?.site_id
  const groupEditScopeSiteId = isSiteBoundGroup
    ? selected!.site_id
    : (editScope === 'site' ? editSiteId : null)
  const groupPreviewSiteId = isSiteBoundGroup
    ? selected!.site_id
    : (editScope === 'site' ? editSiteId : null)
  const editSiteName = editSiteId ? sites.find((s) => s.id === editSiteId)?.name : null

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h3 className="text-sm font-semibold flex items-center gap-2">
            <Users className="h-4 w-4" />
            {t('cal_groups.title', 'Grups de calendari')}
          </h3>
          <p className="text-xs text-muted-foreground mt-0.5">
            {t('cal_groups.description', 'Cada empleat només pot tenir un grup assignat. Definiu patrons compartits i ajustos per local.')}
          </p>
        </div>
        <Button size="sm" className="gap-1.5 h-8" onClick={openNew}>
          <Plus className="h-3.5 w-3.5" />
          {t('cal_groups.new_group', 'Nou grup')}
        </Button>
      </div>

      {/* Form */}
      {showForm && (
        <div className="rounded-lg border bg-muted/30 p-4 space-y-3">
          <p className="text-xs font-semibold">
            {editingId ? t('cal_groups.edit_group', 'Editar grup') : t('cal_groups.new_group', 'Nou grup')}
          </p>
          {!editingId && (
            <div className="space-y-2">
              <Label className="text-xs">{t('cal_groups.scope_label', 'On aplica aquest grup?')}</Label>
              <div className="flex flex-wrap gap-2">
                <button
                  type="button"
                  className={`rounded-md border px-3 py-1.5 text-xs transition-colors ${form.scope === 'global' ? 'border-primary bg-primary/10 font-medium' : 'hover:bg-muted'}`}
                  onClick={() => setForm((f) => ({ ...f, scope: 'global' }))}
                >
                  {t('cal_groups.scope_global', 'Tota l\'empresa')}
                </button>
                <button
                  type="button"
                  className={`rounded-md border px-3 py-1.5 text-xs transition-colors ${form.scope === 'site' ? 'border-primary bg-primary/10 font-medium' : 'hover:bg-muted'}`}
                  onClick={() => setForm((f) => ({ ...f, scope: 'site', siteId: f.siteId || sites[0]?.id || '' }))}
                >
                  {t('cal_groups.scope_site', 'Un local concret')}
                </button>
              </div>
              {form.scope === 'site' && (
                <select
                  value={form.siteId}
                  onChange={(e) => setForm((f) => ({ ...f, siteId: e.target.value }))}
                  className="w-full max-w-xs border rounded-md h-8 px-2 text-xs bg-background"
                >
                  <option value="">{t('cal_groups.pick_site', 'Selecciona un local…')}</option>
                  {sites.map((s) => (
                    <option key={s.id} value={s.id}>{s.name}</option>
                  ))}
                </select>
              )}
              <p className="text-[11px] text-muted-foreground">
                {form.scope === 'global'
                  ? t('cal_groups.scope_global_help', 'Patró comú per a tots els locals. Podeu afegir ajustos per local després.')
                  : t('cal_groups.scope_site_help', 'El grup només aplica als empleats d\'aquest local.')}
              </p>
            </div>
          )}
          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1">
              <Label className="text-xs">{t('cal_groups.name_label', 'Nom')}</Label>
              <Input
                value={form.name}
                onChange={(e) => setForm((f) => ({ ...f, name: e.target.value }))}
                placeholder={t('cal_groups.name_placeholder', 'p.ex. Horari continu')}
                className="h-8 text-sm"
              />
            </div>
            <div className="space-y-1">
              <Label className="text-xs">{t('cal_groups.description_label', 'Descripció (opcional)')}</Label>
              <Input
                value={form.description}
                onChange={(e) => setForm((f) => ({ ...f, description: e.target.value }))}
                placeholder={t('cal_groups.description_placeholder', 'Descripció breu')}
                className="h-8 text-sm"
              />
            </div>
          </div>
          <div className="space-y-1">
            <Label className="text-xs">{t('cal_groups.color_label', 'Color identificador')}</Label>
            <div className="flex items-center gap-2 flex-wrap">
              {COLOR_PRESETS.map((c) => (
                <button
                  key={c}
                  type="button"
                  className={`h-6 w-6 rounded-full transition-transform ${form.color === c ? 'scale-125 ring-2 ring-offset-1 ring-foreground' : 'hover:scale-110'}`}
                  style={{ backgroundColor: c }}
                  onClick={() => setForm((f) => ({ ...f, color: c }))}
                />
              ))}
              <input
                type="color"
                value={form.color}
                onChange={(e) => setForm((f) => ({ ...f, color: e.target.value }))}
                className="h-6 w-10 rounded cursor-pointer border-0"
                title={t('cal_groups.custom_color', 'Color personalitzat')}
              />
            </div>
          </div>
          <AttendanceGeoEnabledField
            value={form.attendance_geo_enabled}
            onChange={(v) => setForm((f) => ({ ...f, attendance_geo_enabled: v }))}
            inheritLabel={t('cal_groups.attendance_geo_inherit', 'Heretar (tenant)')}
            hint={t(
              'cal_groups.attendance_geo_hint',
              'Override per als empleats assignats a aquest grup que no tinguin valor propi.',
            )}
          />
          <AttendancePunchOnlyAtStationsField
            value={form.punch_only_at_stations}
            onChange={(v) => setForm((f) => ({ ...f, punch_only_at_stations: v }))}
            inheritLabel={t('cal_groups.punch_only_inherit', 'Heretar (site / tenant)')}
            hint={t(
              'cal_groups.punch_only_hint',
              'Override massiu del canal de fitxatge. «Només estacions» bloqueja el portal/mòbil; la consulta d’horari i el QR d’identitat queden.',
            )}
          />
          <div className="flex gap-2 pt-1">
            <Button size="sm" disabled={isPending || !form.name.trim() || (form.scope === 'site' && !form.siteId)} onClick={handleSave} className="gap-1">
              <Check className="h-3.5 w-3.5" />
              {t('cal_groups.save', 'Desar')}
            </Button>
            <Button size="sm" variant="ghost" onClick={() => setShowForm(false)}>
              <X className="h-3.5 w-3.5" />
            </Button>
          </div>
        </div>
      )}

      {/* List */}
      {isLoading ? (
        <p className="text-xs text-muted-foreground">{t('cal_groups.loading', 'Carregant grups…')}</p>
      ) : groups.length === 0 ? (
        <div className="rounded-lg border-2 border-dashed border-border p-8 text-center text-sm text-muted-foreground">
          {t('cal_groups.empty', "Encara no hi ha grups de calendari. Creeu-ne un per establir overrides compartits.")}
        </div>
      ) : (
        <div className="rounded-lg border divide-y">
          {groups.map((g) => (
            <div
              key={g.id}
              className={`flex items-center gap-3 px-4 py-3 cursor-pointer transition-colors hover:bg-muted/30 ${selected?.id === g.id ? 'bg-muted/40' : ''}`}
              onClick={() => selectGroup(selected?.id === g.id ? null : g)}
            >
              <div className="h-4 w-4 rounded-full shrink-0" style={{ backgroundColor: g.color }} />
              <div className="flex-1 min-w-0">
                <p className="text-sm font-medium truncate">{g.name}</p>
                {g.description && (
                  <p className="text-xs text-muted-foreground truncate">{g.description}</p>
                )}
                <p className="text-[10px] text-muted-foreground">
                  {g.site_id
                    ? t('cal_groups.badge_site_named', 'Grup de local · {{name}}', {
                        name: sites.find((s) => s.id === g.site_id)?.name ?? '—',
                      })
                    : t('cal_groups.badge_global', 'Grup global')}
                </p>
              </div>
              <button
                type="button"
                className="text-muted-foreground hover:text-foreground shrink-0 p-1 rounded"
                onClick={(e) => { e.stopPropagation(); openEdit(g) }}
              >
                <Pencil className="h-3.5 w-3.5" />
              </button>
              <button
                type="button"
                className="text-muted-foreground hover:text-destructive shrink-0 p-1 rounded"
                onClick={(e) => { e.stopPropagation(); setDeleteTarget(g) }}
              >
                <Trash2 className="h-3.5 w-3.5" />
              </button>
            </div>
          ))}
        </div>
      )}

      {/* Calendar grid per al grup seleccionat */}
      {selected && (
        <div className="space-y-3">
          {!isSiteBoundGroup && (
            <div className="rounded-lg border bg-muted/20 px-4 py-3 space-y-2">
              <p className="text-xs font-medium">{t('cal_groups.edit_scope_label', 'Què esteu editant?')}</p>
              <div className="flex flex-wrap items-center gap-2">
                <button
                  type="button"
                  className={`rounded-md border px-3 py-1.5 text-xs transition-colors ${editScope === 'global' ? 'border-primary bg-primary/10 font-medium' : 'hover:bg-muted'}`}
                  onClick={() => setEditScope('global')}
                >
                  {t('cal_groups.edit_scope_global', 'Patró comú')}
                </button>
                <button
                  type="button"
                  className={`rounded-md border px-3 py-1.5 text-xs transition-colors ${editScope === 'site' ? 'border-primary bg-primary/10 font-medium' : 'hover:bg-muted'}`}
                  onClick={() => setEditScope('site')}
                >
                  {t('cal_groups.edit_scope_site', 'Excepció en un centre')}
                </button>
                {editScope === 'site' && (
                  <select
                    value={editSiteId ?? ''}
                    onChange={(e) => setEditSiteId(e.target.value || null)}
                    className="border rounded-md h-8 px-2 text-xs bg-background"
                  >
                    {sites.map((s) => (
                      <option key={s.id} value={s.id}>{s.name}</option>
                    ))}
                  </select>
                )}
              </div>
              <p className="text-[11px] text-muted-foreground">
                {editScope === 'global'
                  ? t('cal_groups.edit_scope_global_help', 'Horari per defecte del grup a tots els centres. Si cada centre té el seu horari, creeu un grup de local.')
                  : t('cal_groups.edit_scope_site_help', 'Excepció del mateix grup només a {{site}}: el grup s\'assigna a empleats de diversos centres, però aquí cal un dia diferent (p. ex. vigilant en festiu). Si l\'horari és només d\'un centre, creeu un grup de local.', { site: editSiteName ?? '—' })}
              </p>
            </div>
          )}
          <GroupWeeklyBaseSection groupId={selected.id} />
          <AttendanceRecordPolicyEditor
            groupId={selected.id}
            siteId={groupEditScopeSiteId}
          />
          <LaborCalendarGrid
            calendarGroupId={selected.id}
            calendarGroupSiteId={selected.site_id}
            calendarGroupName={selected.name}
            calendarGroupColor={selected.color}
            groupEditScopeSiteId={groupEditScopeSiteId}
            groupPreviewSiteId={groupPreviewSiteId}
          />
        </div>
      )}

      {deleteTarget && (
        <DeleteCalendarGroupDialog
          group={deleteTarget}
          groups={groups}
          open={!!deleteTarget}
          onOpenChange={(open) => { if (!open) setDeleteTarget(null) }}
          onDeleted={() => {
            if (selected?.id === deleteTarget.id) setSelected(null)
            setDeleteTarget(null)
          }}
        />
      )}
    </div>
  )
}
