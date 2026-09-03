import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Plus, Trash2, CalendarDays, Download, Building2, MapPin, Info, ChevronDown, ChevronUp, CheckCircle2, AlertCircle, Pencil, Eye, EyeOff, X } from 'lucide-react'
import { useTenant } from '@/contexts/TenantContext'
import { useCalendarDisplaySettings } from '@/hooks/useCalendarDisplaySettings'
import { formatIsoDateWithPattern } from '@/lib/formatDatePattern'
import {
  useCalendarHolidays,
  useHolidayCalendars,
  useSiteHolidayCalendarAssignments,
  useTenantHolidayCalendarAssignments,
  useAssignHolidayCalendar,
  useRemoveHolidayCalendarFromSite,
  useAssignHolidayCalendarToTenant,
  useRemoveTenantHolidayCalendarAssignment,
  useImportNagerHolidays,
  useCreateHolidayCalendar,
  useDeleteHolidayCalendar,
  useCreateHoliday,
  useUpdateHoliday,
  useDeleteHoliday,
  useSiteHolidayExclusions,
  useToggleSiteHolidayExclusion,
} from '@/features/attendance/api/useShifts'
import type { Holiday, HolidayType } from '@/features/attendance/api/shiftsService'

// ─── Create Holiday Calendar Dialog ──────────────────────────────────────────

interface CreateCalendarDialogProps {
  onClose: () => void
}

const COUNTRY_OPTIONS = [
  { code: 'ES', label: 'Espanya (ES)' },
  { code: 'PT', label: 'Portugal (PT)' },
  { code: 'FR', label: 'Franca (FR)' },
  { code: 'IT', label: 'Italia (IT)' },
  { code: 'DE', label: 'Alemanya (DE)' },
  { code: 'GB', label: 'Regne Unit (GB)' },
] as const

const REGION_OPTIONS_BY_COUNTRY: Record<string, Array<{ code: string; label: string }>> = {
  ES: [
    { code: 'CT', label: 'Catalunya (CT)' },
    { code: 'MD', label: 'Comunitat de Madrid (MD)' },
    { code: 'VC', label: 'Comunitat Valenciana (VC)' },
    { code: 'AN', label: 'Andalusia (AN)' },
    { code: 'PV', label: 'Pais Basc (PV)' },
    { code: 'GA', label: 'Galicia (GA)' },
  ],
}

function CreateCalendarDialog({ onClose }: CreateCalendarDialogProps) {
  const { t } = useTranslation('attendance')
  const { selectedTenantId } = useTenant()
  const { mutate, isPending } = useCreateHolidayCalendar()

  const [name, setName] = useState('')
  const [year, setYear] = useState(new Date().getFullYear())
  const [countryCode, setCountryCode] = useState('ES')
  const [regionCode, setRegionCode] = useState('')
  const regionOptions = REGION_OPTIONS_BY_COUNTRY[countryCode] ?? []

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!selectedTenantId) return
    mutate(
      { name, tenantId: selectedTenantId, year, countryCode, regionCode: regionCode || undefined },
      { onSuccess: onClose },
    )
  }

  return (
    <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50">
      <div className="bg-background rounded-lg shadow-lg p-6 w-full max-w-md mx-4">
        <h2 className="text-lg font-semibold mb-4">
          {t('setup.calendar_new', 'Nou calendari de festius')}
        </h2>
        <form onSubmit={handleSubmit} className="flex flex-col gap-4">
          <div>
            <label className="text-sm font-medium mb-1 block">{t('setup.calendar_name', 'Nom')}</label>
            <input
              value={name}
              onChange={e => setName(e.target.value)}
              className="w-full border rounded-md px-3 py-2 text-sm bg-background"
              required
            />
          </div>
          <p className="text-xs text-muted-foreground rounded-md border bg-muted/20 p-2">
            {t('setup.calendar_fields_help', 'Any, pais i regio defineixen de quina font oficial s\'importaran els festius (Nager.Date). Selecciona valors valids per evitar calendaris buits.')}
          </p>

          <div className="grid grid-cols-3 gap-3">
            <div>
              <label className="text-sm font-medium mb-1 block">{t('setup.calendar_year', 'Any')}</label>
              <select
                value={year}
                onChange={e => setYear(Number(e.target.value))}
                className="w-full border rounded-md px-3 py-2 text-sm bg-background"
              >
                {[year - 1, year, year + 1, year + 2].map(optionYear => (
                  <option key={optionYear} value={optionYear}>{optionYear}</option>
                ))}
              </select>
            </div>
            <div>
              <label className="text-sm font-medium mb-1 block">{t('setup.calendar_country', 'País')}</label>
              <select
                value={countryCode}
                onChange={e => {
                  setCountryCode(e.target.value)
                  setRegionCode('')
                }}
                className="w-full border rounded-md px-3 py-2 text-sm bg-background"
              >
                {COUNTRY_OPTIONS.map(country => (
                  <option key={country.code} value={country.code}>{country.label}</option>
                ))}
              </select>
            </div>
            <div>
              <label className="text-sm font-medium mb-1 block">{t('setup.calendar_region', 'Regió')}</label>
              <select
                value={regionCode}
                className="w-full border rounded-md px-3 py-2 text-sm bg-background"
                onChange={e => setRegionCode(e.target.value)}
                disabled={regionOptions.length === 0}
              >
                <option value="">{t('setup.calendar_region_none', 'Sense regió (nacional)')}</option>
                {regionOptions.map(region => (
                  <option key={region.code} value={region.code}>{region.label}</option>
                ))}
              </select>
            </div>
          </div>
          <div className="flex gap-2 justify-end">
            <button type="button" onClick={onClose} className="px-4 py-2 text-sm rounded-md border hover:bg-accent">
              {t('setup.cancel', 'Cancel·lar')}
            </button>
            <button
              type="submit"
              disabled={isPending}
              className="px-4 py-2 text-sm rounded-md bg-primary text-primary-foreground hover:bg-primary/90 disabled:opacity-50"
            >
              {isPending ? t('setup.creating', 'Creant...') : t('setup.create', 'Crear')}
            </button>
          </div>
        </form>
      </div>
    </div>
  )
}

// ─── Import Holidays Dialog ───────────────────────────────────────────────────

interface ImportDialogProps {
  calendarId: string
  calendarName: string
  countryCode: string
  regionCode?: string
  year: number
  onClose: () => void
}

interface CalendarHolidayPreviewProps {
  calendarId: string | null
  year: number | null
  open: boolean
  isReadonly?: boolean
}

function CalendarHolidayPreview({ calendarId, year, open, isReadonly = false }: CalendarHolidayPreviewProps) {
  const { t } = useTranslation('attendance')
  const { selectedSiteId } = useTenant()
  const { dateFormat } = useCalendarDisplaySettings()
  const resolvedYear = year ?? new Date().getFullYear()
  const { data: holidays = [], isLoading } = useCalendarHolidays(calendarId, resolvedYear, open)
  const { mutate: deleteHoliday, isPending: deleting } = useDeleteHoliday()
  const { data: exclusions = [] } = useSiteHolidayExclusions()
  const { mutate: toggleExclusion, isPending: togglingExclusion } = useToggleSiteHolidayExclusion()
  const [editTarget, setEditTarget] = useState<Holiday | null>(null)
  const [showAddForm, setShowAddForm] = useState(false)

  // Conjunt d'IDs de festius d'aquest calendari exclosos per al site actual
  const calendarHolidayIds = new Set(holidays.map(h => h.id))
  const excludedHolidayIds = new Set(
    exclusions
      .filter(e => e.holiday_id && calendarHolidayIds.has(e.holiday_id))
      .map(e => e.holiday_id!),
  )

  if (!open) return null

  return (
    <div className="mt-3 rounded-md border bg-muted/20 p-3">
      {isLoading ? (
        <p className="text-xs text-muted-foreground">{t('setup.loading', 'Carregant...')}</p>
      ) : (
        <>
          {holidays.length === 0 ? (
            <p className="text-xs text-muted-foreground mb-3">
              {t('setup.calendar_holidays_empty', 'Aquest calendari encara no té festius importats per a aquest any.')}
            </p>
          ) : (
            <div className="space-y-0.5 max-h-52 overflow-y-auto pr-1 mb-3">
              <p className="text-xs text-muted-foreground mb-2">
                {t('setup.calendar_holidays_count', '{{count}} festius carregats', { count: holidays.length })}
              </p>
              {holidays.map(h => {
                const isExcluded = h.id ? excludedHolidayIds.has(h.id) : false
                return (
                  <div
                    key={h.id}
                    className={`text-xs flex items-center gap-2 group rounded px-1 py-0.5 hover:bg-accent/40 ${isExcluded ? 'opacity-40' : ''}`}
                  >
                    <span className="text-muted-foreground w-24 shrink-0 tabular-nums">
                      {h.date ? formatIsoDateWithPattern(h.date.slice(0, 10), dateFormat) : '—'}
                    </span>
                    <span className={`font-medium flex-1 truncate ${isExcluded ? 'line-through' : ''}`}>{h.name}</span>
                    {h.is_half_day && !isExcluded && (
                      <span className="px-1 py-0.5 rounded bg-amber-100 text-amber-700 text-[10px] shrink-0">
                        {t('setup.holiday_half_day', 'Mig dia')}
                      </span>
                    )}

                    {isReadonly && selectedSiteId && h.id ? (
                      /* Toggle exclusió: visible on hover */
                      <button
                        onClick={() => toggleExclusion({ siteId: selectedSiteId, holidayId: h.id!, isExcluded: !isExcluded })}
                        disabled={togglingExclusion}
                        className={`opacity-0 group-hover:opacity-100 p-0.5 rounded shrink-0 disabled:opacity-30 transition-opacity ${
                          isExcluded
                            ? 'text-green-600 hover:bg-green-100'
                            : 'text-slate-400 hover:bg-red-100 hover:text-red-500'
                        }`}
                        title={
                          isExcluded
                            ? t('setup.holiday_include', 'Activar per a aquest centre')
                            : t('setup.holiday_exclude', 'Desactivar per a aquest centre')
                        }
                      >
                        {isExcluded ? <Eye className="h-3 w-3" /> : <EyeOff className="h-3 w-3" />}
                      </button>
                    ) : !isReadonly && (
                      <>
                        <button
                          onClick={() => setEditTarget(h)}
                          className="opacity-0 group-hover:opacity-100 p-0.5 rounded hover:bg-accent shrink-0"
                          title={t('setup.holiday_edit', 'Editar festiu')}
                        >
                          <Pencil className="h-3 w-3" />
                        </button>
                        <button
                          onClick={() => h.id && deleteHoliday(h.id)}
                          disabled={deleting}
                          className="opacity-0 group-hover:opacity-100 p-0.5 rounded hover:bg-red-100 text-red-600 shrink-0 disabled:opacity-30"
                          title={t('setup.holiday_delete', 'Eliminar festiu')}
                        >
                          <Trash2 className="h-3 w-3" />
                        </button>
                      </>
                    )}
                  </div>
                )
              })}
            </div>
          )}
          {!isReadonly && (
            <button
              onClick={() => setShowAddForm(true)}
              className="flex items-center gap-1 text-xs text-primary hover:underline mt-1"
            >
              <Plus className="h-3 w-3" />
              {t('setup.holiday_add_manual', 'Afegir festiu manualment')}
            </button>
          )}
          {isReadonly && (
            <p className="text-[11px] text-muted-foreground mt-1 italic">
              {t('setup.holiday_inherited_hint', 'Passa el cursor per un festiu per activar/desactivar-lo en aquest centre.')}
            </p>
          )}
        </>
      )}

      {(showAddForm || editTarget) && calendarId && (
        <HolidayFormDialog
          calendarId={calendarId}
          existing={editTarget}
          onClose={() => { setShowAddForm(false); setEditTarget(null) }}
        />
      )}
    </div>
  )
}

// ─── Holiday Form Dialog (create / edit) ─────────────────────────────────────

interface HolidayFormDialogProps {
  calendarId: string
  existing: Holiday | null
  onClose: () => void
}

function HolidayFormDialog({ calendarId, existing, onClose }: HolidayFormDialogProps) {
  const { t } = useTranslation('attendance')
  const { mutate: createHoliday } = useCreateHoliday()
  const { mutate: updateHoliday } = useUpdateHoliday()

  const [date, setDate] = useState(existing?.date?.slice(0, 10) ?? '')
  const [name, setName] = useState(existing?.name ?? '')
  const [holidayType, setHolidayType] = useState<HolidayType>(
    (existing?.holiday_type as HolidayType) ?? 'tenant_custom',
  )
  const [isHalfDay, setIsHalfDay] = useState(existing?.is_half_day ?? false)
  const [submitting, setSubmitting] = useState(false)

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    setSubmitting(true)
    const done = () => { setSubmitting(false); onClose() }
    const fail = () => setSubmitting(false)
    if (existing?.id) {
      updateHoliday({ id: existing.id, date, name, holidayType, isHalfDay }, { onSuccess: done, onError: fail })
    } else {
      createHoliday({ calendarId, date, name, holidayType, isHalfDay }, { onSuccess: done, onError: fail })
    }
  }

  return (
    <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50">
      <div className="bg-background rounded-lg shadow-lg p-6 w-full max-w-sm mx-4">
        <h2 className="text-lg font-semibold mb-4">
          {existing
            ? t('setup.holiday_edit_title', 'Editar festiu')
            : t('setup.holiday_add_title', 'Nou festiu manual')}
        </h2>
        <form onSubmit={handleSubmit} className="flex flex-col gap-4">
          <div>
            <label className="text-sm font-medium mb-1 block">{t('setup.holiday_date', 'Data')}</label>
            <input
              type="date"
              value={date}
              onChange={e => setDate(e.target.value)}
              className="w-full border rounded-md px-3 py-2 text-sm bg-background"
              required
            />
          </div>
          <div>
            <label className="text-sm font-medium mb-1 block">{t('setup.holiday_name_label', 'Nom')}</label>
            <input
              type="text"
              value={name}
              onChange={e => setName(e.target.value)}
              className="w-full border rounded-md px-3 py-2 text-sm bg-background"
              placeholder={t('setup.holiday_name_placeholder', 'Ex: Diada de Catalunya')}
              required
            />
          </div>
          <div>
            <label className="text-sm font-medium mb-1 block">{t('setup.holiday_type_label', 'Tipus')}</label>
            <select
              value={holidayType}
              onChange={e => setHolidayType(e.target.value as HolidayType)}
              className="w-full border rounded-md px-3 py-2 text-sm bg-background"
            >
              <option value="national">{t('setup.holiday_type_national', 'Nacional')}</option>
              <option value="regional">{t('setup.holiday_type_regional', 'Regional')}</option>
              <option value="local">{t('setup.holiday_type_local', 'Local')}</option>
              <option value="tenant_custom">{t('setup.holiday_type_custom', 'Personalitzat (empresa)')}</option>
            </select>
          </div>
          <label className="flex items-center gap-2 text-sm cursor-pointer">
            <input
              type="checkbox"
              checked={isHalfDay}
              onChange={e => setIsHalfDay(e.target.checked)}
              className="rounded"
            />
            {t('setup.holiday_is_half_day', 'Mig dia festiu (jornada reduïda)')}
          </label>
          <div className="flex gap-2 justify-end pt-2">
            <button type="button" onClick={onClose} className="px-4 py-2 text-sm rounded-md border hover:bg-accent">
              {t('setup.cancel', 'Cancel·lar')}
            </button>
            <button
              type="submit"
              disabled={submitting}
              className="px-4 py-2 text-sm rounded-md bg-primary text-primary-foreground hover:bg-primary/90 disabled:opacity-50"
            >
              {submitting ? t('setup.saving', 'Desant...') : t('setup.save', 'Desar')}
            </button>
          </div>
        </form>
      </div>
    </div>
  )
}
function ImportHolidaysDialog({ calendarId, calendarName, countryCode, regionCode, year, onClose }: ImportDialogProps) {
  const { t } = useTranslation('attendance')
  const { mutate, isPending } = useImportNagerHolidays()

  function handleImport() {
    mutate({ calendarId, year, countryCode, regionCode }, { onSuccess: onClose })
  }

  return (
    <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50">
      <div className="bg-background rounded-lg shadow-lg p-6 w-full max-w-sm mx-4">
        <h2 className="text-lg font-semibold mb-2">
          {t('setup.import_confirm_title', 'Importar festius de Nager.Date')}
        </h2>
        <p className="text-sm text-muted-foreground mb-4">
          {t('setup.import_confirm_desc', 'Importarà els festius per a {{name}} ({{country}}, {{year}}).', {
            name: calendarName,
            country: countryCode,
            year,
          })}
        </p>
        <div className="flex gap-2 justify-end">
          <button type="button" onClick={onClose} className="px-4 py-2 text-sm rounded-md border hover:bg-accent">
            {t('setup.cancel', 'Cancel·lar')}
          </button>
          <button
            onClick={handleImport}
            disabled={isPending}
            className="px-4 py-2 text-sm rounded-md bg-primary text-primary-foreground hover:bg-primary/90 disabled:opacity-50"
          >
            {isPending ? t('setup.importing', 'Important...') : t('setup.import_now', 'Importar')}
          </button>
        </div>
      </div>
    </div>
  )
}

// ─── Main Page ────────────────────────────────────────────────────────────────

interface LaborCalendarSetupPageProps {
  /** @deprecated EX-03.2 — only holidays remain; kept for PlanificacioPage callers */
  onlyTab?: 'holidays' | 'schedules'
  alwaysShowHolidays?: boolean
  /** Embedded Festius tab in Planificació — use holiday-specific titles */
  holidaysOnly?: boolean
}

export function LaborCalendarSetupPage({ alwaysShowHolidays = false, holidaysOnly = false }: LaborCalendarSetupPageProps = {}) {
  const { t } = useTranslation('attendance')
  const { selectedSiteId, activeSite } = useTenant()
  const [showCreateCalendar, setShowCreateCalendar] = useState(false)
  const [expandedCalendarId, setExpandedCalendarId] = useState<string | null>(null)
  const [deleteCalendarConfirm, setDeleteCalendarConfirm] = useState<string | null>(null)
  const [importTarget, setImportTarget] = useState<{
    id: string; name: string; countryCode: string; regionCode?: string; year: number
  } | null>(null)

  // Calendaris disponibles (del tenant)
  const { data: calendars = [], isLoading: calLoading } = useHolidayCalendars()

  // Assignacions site-level (si hi ha site seleccionat)
  const { data: siteAssignments = [] } = useSiteHolidayCalendarAssignments()
  const { mutate: assignToSite, isPending: assigningToSite } = useAssignHolidayCalendar()
  const { mutate: removeFromSite, isPending: removingFromSite } = useRemoveHolidayCalendarFromSite()

  // Assignacions tenant-level (quan no hi ha site seleccionat)
  const { data: tenantAssignments = [] } = useTenantHolidayCalendarAssignments()
  const { mutate: assignToTenant, isPending: assigningToTenant } = useAssignHolidayCalendarToTenant()
  const { mutate: removeFromTenant, isPending: removingFromTenant } = useRemoveTenantHolidayCalendarAssignment()
  const { mutate: deleteCalendar, isPending: deletingCalendar } = useDeleteHolidayCalendar()

  // Context: site o tenant
  const isSiteContext = !!selectedSiteId
  const activeAssignments = isSiteContext ? siteAssignments : tenantAssignments
  const tenantAssignedCalendarIds = new Set(tenantAssignments.map(a => a.calendar_id))
  const assignedCalendarIds = new Set(activeAssignments.map(a => a.calendar_id))
  const assigning = isSiteContext ? assigningToSite : assigningToTenant
  const removing = isSiteContext ? removingFromSite : removingFromTenant

  function handleAssign(calendarId: string) {
    if (isSiteContext) assignToSite(calendarId)
    else assignToTenant(calendarId)
  }

  function handleRemove(assignmentId: string) {
    if (isSiteContext) removeFromSite(assignmentId)
    else removeFromTenant(assignmentId)
  }

  return (
    <div className={holidaysOnly ? '' : 'p-6 max-w-4xl mx-auto'}>
      {/* Header */}
      <div className="flex items-center gap-2 mb-4">
        <CalendarDays className="h-5 w-5 text-muted-foreground" />
        <h1 className="text-2xl font-semibold">
          {holidaysOnly
            ? t('setup.holidays_title', 'Calendari de festius')
            : t('setup.title', 'Calendari laboral')}
        </h1>
      </div>

      {/* Context banner — indica si s'edita a nivell de tenant o de centre */}
      <div
        className={`flex items-start gap-3 rounded-lg border px-4 py-3 mb-6 text-sm ${
          isSiteContext
            ? 'bg-blue-50 border-blue-200 text-blue-800 dark:bg-blue-950/30 dark:border-blue-800 dark:text-blue-200'
            : 'bg-amber-50 border-amber-200 text-amber-800 dark:bg-amber-950/30 dark:border-amber-800 dark:text-amber-200'
        }`}
      >
        {isSiteContext ? (
          <MapPin className="h-4 w-4 mt-0.5 shrink-0" />
        ) : (
          <Building2 className="h-4 w-4 mt-0.5 shrink-0" />
        )}
        <div className="flex-1 min-w-0">
          <p className="font-medium">
            {isSiteContext
              ? t('setup.context_site', 'Configuració del centre: {{siteName}}', {
                  siteName: activeSite?.name ?? selectedSiteId,
                })
              : t('setup.context_tenant', 'Configuració per defecte del tenant')}
          </p>
          <p className="mt-0.5 text-xs opacity-80">
            {isSiteContext
              ? t(
                  'setup.context_site_desc',
                  'Estàs editant la configuració específica d\'aquest centre. Els centres sense configuració pròpia heretaran els valors del tenant.',
                )
              : t(
                  'setup.context_tenant_desc',
                  'Estàs editant els valors per defecte que hereten tots els centres sense configuració específica. Selecciona un centre per editar-lo individualment.',
                )}
          </p>
        </div>
        <Info className="h-3.5 w-3.5 mt-0.5 shrink-0 opacity-60" />
      </div>

      {/* ── Festius (ADR-0003: work_schedules retirades, base recurrent al planner) ───────────── */}
      <div>
          <div className="flex items-center justify-between mb-4">
            <p className="text-sm text-muted-foreground">
              {isSiteContext
                ? t('setup.holidays_desc_site', 'Calendaris de festius assignats a aquest centre.')
                : t('setup.holidays_desc_tenant', 'Calendaris de festius per defecte del tenant. S\'apliquen als centres sense calendari propi.')}
            </p>
            <button
              onClick={() => setShowCreateCalendar(true)}
              className="flex items-center gap-1.5 px-3 py-1.5 rounded-md bg-primary text-primary-foreground text-sm hover:bg-primary/90"
            >
              <Plus className="h-3.5 w-3.5" />
              {holidaysOnly
                ? t('setup.calendar_new_holiday_btn', 'Nou calendari de festius')
                : t('setup.calendar_new_btn', 'Nou calendari')}
            </button>
          </div>

          {calLoading ? (
            <div className="text-sm text-muted-foreground py-8 text-center">
              {t('setup.loading', 'Carregant...')}
            </div>
          ) : calendars.length === 0 ? (
            <div className="text-sm text-muted-foreground py-12 text-center border rounded-lg">
              {t('setup.calendar_empty', 'Cap calendari de festius creat')}
            </div>
          ) : (
            <div className="flex flex-col gap-2">
              {calendars.map(cal => {
                const isAssigned = assignedCalendarIds.has(cal.id)
                const assignment = activeAssignments.find(a => a.calendar_id === cal.id)
                const isInheritedFromTenant = isSiteContext && !isAssigned && tenantAssignedCalendarIds.has(cal.id)
                const isExpanded = alwaysShowHolidays || expandedCalendarId === cal.id
                return (
                  <div
                    key={cal.id}
                    className="border rounded-lg p-4"
                  >
                    <div className="flex flex-col sm:flex-row sm:items-center gap-3">
                      <div className="flex-1 min-w-0">
                        <p className="font-medium text-sm">{cal.name}</p>
                        <p className="text-xs text-muted-foreground">
                          {cal.country_code}{cal.region_code ? ` / ${cal.region_code}` : ''} · {cal.year}
                        </p>
                        <div className="mt-2 flex flex-wrap gap-2">
                          {isAssigned && (
                            <span className="text-[11px] inline-flex items-center gap-1 rounded-full bg-emerald-100 text-emerald-800 px-2 py-0.5">
                              <CheckCircle2 className="h-3 w-3" />
                              {isSiteContext
                                ? t('setup.assigned_to_current_site', 'Assignat al centre actual')
                                : t('setup.assigned_to_tenant', 'Assignat al tenant (per defecte)')}
                            </span>
                          )}
                          {isInheritedFromTenant && (
                            <span className="text-[11px] inline-flex items-center gap-1 rounded-full bg-amber-100 text-amber-800 px-2 py-0.5">
                              <AlertCircle className="h-3 w-3" />
                              {t('setup.inherited_from_tenant', 'Heretat del tenant')}
                            </span>
                          )}
                        </div>
                      </div>

                      <div className="flex items-center gap-2 shrink-0 flex-wrap">
                        {/* Import: no per a calendaris heretats */}
                        {!isInheritedFromTenant && (
                          <button
                            onClick={() =>
                              setImportTarget({
                                id: cal.id ?? '',
                                name: cal.name ?? '',
                                countryCode: cal.country_code ?? 'ES',
                                regionCode: cal.region_code ?? undefined,
                                year: cal.year ?? new Date().getFullYear(),
                              })
                            }
                            className="flex items-center gap-1 px-2.5 py-1.5 text-xs rounded-md border hover:bg-accent"
                            title={t('setup.import_nager', 'Importar des de Nager.Date')}
                          >
                            <Download className="h-3 w-3" />
                            {t('setup.import_btn', 'Importar festius')}
                          </button>
                        )}

                        {!alwaysShowHolidays && (
                        <button
                          onClick={() => setExpandedCalendarId(isExpanded ? null : cal.id ?? null)}
                          className="flex items-center gap-1 px-2.5 py-1.5 text-xs rounded-md border hover:bg-accent"
                        >
                          {isExpanded ? <ChevronUp className="h-3 w-3" /> : <ChevronDown className="h-3 w-3" />}
                          {isExpanded
                            ? t('setup.hide_holidays', 'Amagar festius')
                            : t('setup.show_holidays', 'Veure festius')}
                        </button>
                        )}

                        {/* Assignar/Desassignar: no mostrar "Assignar al centre" si ja heretat */}
                        {isAssigned ? (
                          <button
                            onClick={() => assignment?.id && handleRemove(assignment.id)}
                            disabled={removing}
                            className="flex items-center gap-1 px-2.5 py-1.5 text-xs rounded-md bg-red-100 text-red-700 hover:bg-red-200 disabled:opacity-50"
                          >
                            <Trash2 className="h-3 w-3" />
                            {isSiteContext
                              ? t('setup.remove_from_site', 'Desassignar del centre')
                              : t('setup.remove_from_tenant', 'Desassignar del tenant')}
                          </button>
                        ) : !isInheritedFromTenant && (
                          <button
                            onClick={() => cal.id && handleAssign(cal.id)}
                            disabled={assigning}
                            className="flex items-center gap-1 px-2.5 py-1.5 text-xs rounded-md bg-green-100 text-green-700 hover:bg-green-200 disabled:opacity-50"
                          >
                            <Plus className="h-3 w-3" />
                            {isSiteContext
                              ? t('setup.assign_to_site', 'Assignar al centre')
                              : t('setup.assign_to_tenant', 'Assignar al tenant')}
                          </button>
                        )}

                        {/* Eliminar calendari — only when not assigned anywhere */}
                        {!isAssigned && !isInheritedFromTenant && cal.id && (
                          deleteCalendarConfirm === cal.id ? (
                            <span className="inline-flex items-center gap-1">
                              <button
                                onClick={() => {
                                  deleteCalendar(cal.id!, { onSuccess: () => setDeleteCalendarConfirm(null) })
                                }}
                                disabled={deletingCalendar}
                                className="px-2 py-1 text-[11px] rounded-md bg-red-600 text-white hover:bg-red-700 disabled:opacity-50"
                              >
                                {t('setup.calendar_delete_confirm', 'Sí, eliminar')}
                              </button>
                              <button
                                onClick={() => setDeleteCalendarConfirm(null)}
                                className="px-2 py-1 text-[11px] rounded-md border hover:bg-accent"
                              >
                                {t('setup.cancel', 'Cancel·lar')}
                              </button>
                            </span>
                          ) : (
                            <button
                              onClick={() => setDeleteCalendarConfirm(cal.id!)}
                              className="flex items-center gap-1 px-2.5 py-1.5 text-xs rounded-md border border-red-200 text-red-600 hover:bg-red-50"
                              title={t('setup.calendar_delete_title', 'Eliminar calendari')}
                            >
                              <Trash2 className="h-3 w-3" />
                              {t('setup.calendar_delete', 'Eliminar')}
                            </button>
                          )
                        )}
                      </div>
                    </div>

                    <CalendarHolidayPreview
                      calendarId={cal.id}
                      year={cal.year ?? null}
                      open={isExpanded}
                      isReadonly={isInheritedFromTenant}
                    />
                  </div>
                )
              })}
            </div>
          )}
      </div>

      {/* Dialogs */}
      {showCreateCalendar && (
        <CreateCalendarDialog onClose={() => setShowCreateCalendar(false)} />
      )}
      {importTarget && (
        <ImportHolidaysDialog
          calendarId={importTarget.id}
          calendarName={importTarget.name}
          countryCode={importTarget.countryCode}
          regionCode={importTarget.regionCode}
          year={importTarget.year}
          onClose={() => setImportTarget(null)}
        />
      )}
    </div>
  )
}
