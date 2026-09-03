import { useEffect, useMemo, useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Link } from 'react-router-dom'
import {
  AlertTriangle,
  ArrowDown,
  ArrowUp,
  CalendarClock,
  ChevronDown,
  ChevronRight,
  Copy,
  Pencil,
  Plus,
  Trash2,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Textarea } from '@/components/ui/textarea'
import { Badge } from '@/components/ui/badge'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { ChecklistKindIcon } from './ChecklistKindIcon'
import {
  archivePlan,
  clonePlan,
  countUnpublishedPlanTemplates,
  createAssignment,
  createPlan,
  getPlanDetail,
  listAssignments,
  listPlanUpdates,
  listPlatformPlans,
  listPublishedTenantTemplates,
  listTenantPlans,
  setPlanChecklists,
  updatePlan,
  DEFAULT_MAINTENANCE_TIMEZONE,
  MAINTENANCE_ENTITY_TYPES,
  MAINTENANCE_FREQUENCIES,
  MAINTENANCE_LOCALES,
  type MaintenanceEntityType,
  type MaintenanceFrequency,
  type MaintenanceLocale,
  type MaintenancePlan,
  type PlanWriteInput,
} from '../api/maintenancePlansService'

const PAGE_SIZE = 20
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

interface PlanFormState {
  name: string
  description: string
  locale: MaintenanceLocale
  category: string
  frequency: MaintenanceFrequency
  interval_count: number
  timezone: string
  lead_days: number
}

function emptyForm(): PlanFormState {
  return {
    name: '',
    description: '',
    locale: 'ca',
    category: 'general',
    frequency: 'monthly',
    interval_count: 1,
    timezone: DEFAULT_MAINTENANCE_TIMEZONE,
    lead_days: 0,
  }
}

function formFromPlan(plan: MaintenancePlan): PlanFormState {
  return {
    name: plan.name,
    description: plan.description ?? '',
    locale: plan.locale,
    category: plan.category,
    frequency: plan.frequency,
    interval_count: plan.interval_count,
    timezone: plan.timezone,
    lead_days: plan.lead_days,
  }
}

function toWriteInput(form: PlanFormState): PlanWriteInput {
  return {
    name: form.name,
    description: form.description,
    locale: form.locale,
    category: form.category,
    frequency: form.frequency,
    interval_count: form.interval_count,
    timezone: form.timezone,
    lead_days: form.lead_days,
  }
}

/** Read-only rendering of a plan's checklists and their points. */
function PlanContentPreview({ planId }: { planId: string }) {
  const { t } = useTranslation('field-service')
  const { data, isLoading } = useQuery({
    queryKey: ['maintenance_plan_detail', planId],
    queryFn: () => getPlanDetail(planId),
  })

  if (isLoading) {
    return <p className="text-xs text-muted-foreground">{t('templates.loading', 'Carregant…')}</p>
  }
  if (!data || data.checklists.length === 0) {
    return (
      <p className="text-xs text-muted-foreground">
        {t('maintenance.no_checklists', 'Aquest pla no té cap plantilla associada.')}
      </p>
    )
  }

  return (
    <div className="space-y-3">
      <div className="rounded-lg border border-dashed border-border bg-muted/30 px-3 py-2 text-xs text-muted-foreground">
        {t(
          'maintenance.hierarchy_hint',
          'El pla enganxa plantilles publicades. Els punts (ToDo o de revisió) viuen dins de cada plantilla, no al pla.',
        )}
      </div>

      <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
        {t('maintenance.templates_in_plan', 'Plantilles del pla ({{count}})', {
          count: data.checklists.length,
        })}
      </p>

      {data.checklists.map((checklist, index) => {
        const isReview = checklist.template_kind === 'review'
        const pointsLabel = isReview
          ? t('maintenance.review_points_in_template', 'Punts de revisió')
          : t('maintenance.todo_points_in_template', 'Punts ToDo')

        return (
          <div key={checklist.id} className="rounded-xl border border-border bg-card overflow-hidden">
            <div className="flex flex-wrap items-start gap-2 border-b border-border bg-muted/30 px-3 py-2.5">
              <span className="text-xs tabular-nums text-muted-foreground mt-0.5">{index + 1}.</span>
              <div className="min-w-0 flex-1">
                <p className="flex items-center gap-2 text-sm font-medium">
                  <ChecklistKindIcon kind={checklist.template_kind} />
                  <span>
                    {t('maintenance.template_label', 'Plantilla')}: {checklist.template_name}
                  </span>
                </p>
                <div className="mt-1 flex flex-wrap gap-1">
                  <Badge variant="outline">
                    {isReview
                      ? t('maintenance.kind_review', 'Punts de revisió')
                      : t('maintenance.kind_todo', 'Punts ToDo')}
                  </Badge>
                  {checklist.template_locale && (
                    <Badge variant="secondary" className="font-normal">
                      {checklist.template_locale.toUpperCase()}
                    </Badge>
                  )}
                  {checklist.template_category && checklist.template_category !== 'general' && (
                    <Badge variant="secondary" className="font-normal">
                      {checklist.template_category}
                    </Badge>
                  )}
                  {checklist.version_number != null && (
                    <span className="text-xs text-muted-foreground self-center">
                      {t('maintenance.version', 'v{{n}}', { n: checklist.version_number })}
                      {checklist.version_status === 'published'
                        ? ` · ${t('maintenance.published', 'publicada')}`
                        : ''}
                    </span>
                  )}
                </div>
              </div>
            </div>

            <div className="px-3 py-2.5">
              <p className="mb-2 text-xs font-medium text-muted-foreground">
                {pointsLabel}
                <span className="ml-1 tabular-nums">({checklist.items.length})</span>
              </p>
              {checklist.items.length === 0 ? (
                <p className="text-xs text-muted-foreground">
                  {t('maintenance.no_points', 'Sense ítems a la versió publicada.')}
                </p>
              ) : (
                <ol className="space-y-2">
                  {checklist.items.map((item) => (
                    <li key={item.id} className="flex gap-2 text-sm">
                      <span className="tabular-nums text-xs text-muted-foreground mt-0.5 w-4 shrink-0">
                        {item.position + 1}.
                      </span>
                      <div className="min-w-0 flex-1">
                        <p className="font-medium leading-snug">
                          {item.title}
                          {item.is_required && (
                            <span
                              className="ml-1 text-destructive"
                              title={t('editor.required', 'Obligatori')}
                            >
                              *
                            </span>
                          )}
                        </p>
                        {(item.description_public || item.description_internal) && (
                          <p className="mt-0.5 text-xs text-muted-foreground line-clamp-2">
                            {item.description_public || item.description_internal}
                          </p>
                        )}
                        <div className="mt-1 flex flex-wrap gap-1">
                          {item.include_in_report && (
                            <Badge variant="outline" className="text-[10px] font-normal">
                              {t('editor.in_report', 'Incloure al part del client')}
                            </Badge>
                          )}
                          {isReview && item.review_point_id && (
                            <Badge variant="secondary" className="text-[10px] font-normal">
                              {t('maintenance.from_point_catalog', 'Del catàleg de punts')}
                            </Badge>
                          )}
                        </div>
                      </div>
                    </li>
                  ))}
                </ol>
              )}
            </div>
          </div>
        )
      })}
    </div>
  )
}

/** Create/edit form for tenant plans, including the ordered checklist links. */
function PlanEditor({
  tenantId,
  plan,
  onClose,
}: {
  tenantId: string
  plan: MaintenancePlan | null
  onClose: () => void
}) {
  const { t } = useTranslation('field-service')
  const { toast } = useToast()
  const queryClient = useQueryClient()

  const [form, setForm] = useState<PlanFormState>(plan ? formFromPlan(plan) : emptyForm())
  const [templateIds, setTemplateIds] = useState<string[]>([])
  const [saving, setSaving] = useState(false)

  const { data: templates = [] } = useQuery({
    queryKey: ['maintenance_published_templates', tenantId],
    queryFn: () => listPublishedTenantTemplates(tenantId),
  })

  const { data: detail } = useQuery({
    queryKey: ['maintenance_plan_detail', plan?.id],
    queryFn: () => getPlanDetail(plan!.id),
    enabled: !!plan?.id,
  })

  useEffect(() => {
    if (!detail) return
    setTemplateIds(detail.checklists.map((c) => c.template_id))
  }, [detail])

  const templatesById = useMemo(
    () => new Map(templates.map((tpl) => [tpl.id, tpl])),
    [templates],
  )
  const available = templates.filter((tpl) => !templateIds.includes(tpl.id))

  function move(index: number, delta: number) {
    setTemplateIds((prev) => {
      const next = [...prev]
      const target = index + delta
      if (target < 0 || target >= next.length) return prev
      ;[next[index], next[target]] = [next[target], next[index]]
      return next
    })
  }

  async function handleSave() {
    if (!form.name.trim()) {
      toast({
        variant: 'destructive',
        description: t('maintenance.name_required', 'El pla necessita un nom'),
      })
      return
    }
    setSaving(true)
    try {
      let planId: string
      if (plan) {
        await updatePlan(plan.id, tenantId, toWriteInput(form))
        planId = plan.id
      } else {
        planId = await createPlan(tenantId, toWriteInput(form))
      }
      await setPlanChecklists(planId, tenantId, templateIds)
      await queryClient.invalidateQueries({ queryKey: ['maintenance_tenant_plans'] })
      await queryClient.invalidateQueries({ queryKey: ['maintenance_plan_detail', planId] })
      toast({ description: t('maintenance.saved', 'Pla desat') })
      onClose()
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      toast({ variant: 'destructive', description: message })
    } finally {
      setSaving(false)
    }
  }

  return (
    <div className="space-y-4 rounded-xl border border-border p-4">
      <h2 className="font-semibold">
        {plan ? t('maintenance.edit_plan', 'Editar pla') : t('maintenance.new_plan', 'Nou pla')}
      </h2>

      <div className="grid gap-3 sm:grid-cols-2">
        <div className="space-y-1.5 sm:col-span-2">
          <label className="text-sm font-medium">{t('maintenance.field_name', 'Nom')}</label>
          <Input
            value={form.name}
            onChange={(e) => setForm((f) => ({ ...f, name: e.target.value }))}
            placeholder={t('maintenance.name_placeholder', 'Ex: Pla caldera anual')}
          />
        </div>
        <div className="space-y-1.5 sm:col-span-2">
          <label className="text-sm font-medium">
            {t('maintenance.field_description', 'Descripció')}
          </label>
          <Textarea
            rows={2}
            value={form.description}
            onChange={(e) => setForm((f) => ({ ...f, description: e.target.value }))}
          />
        </div>
        <div className="space-y-1.5">
          <label className="text-sm font-medium">{t('maintenance.field_locale', 'Idioma')}</label>
          <Select
            value={form.locale}
            onValueChange={(v) => setForm((f) => ({ ...f, locale: v as MaintenanceLocale }))}
          >
            <SelectTrigger>
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {MAINTENANCE_LOCALES.map((locale) => (
                <SelectItem key={locale} value={locale}>
                  {t(`maintenance.locale_${locale}`, locale)}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        <div className="space-y-1.5">
          <label className="text-sm font-medium">
            {t('maintenance.field_category', 'Categoria')}
          </label>
          <Input
            value={form.category}
            onChange={(e) => setForm((f) => ({ ...f, category: e.target.value }))}
            placeholder="general"
          />
        </div>
      </div>

      <div className="space-y-2">
        <p className="text-sm font-medium">
          {t('maintenance.periodicity', 'Periodicitat per defecte')}
        </p>
        <p className="text-xs text-muted-foreground">
          {t(
            'maintenance.periodicity_help',
            'Aquests valors es copien a cada assignació nova; després es poden ajustar per assignació.',
          )}
        </p>
        <div className="grid gap-3 sm:grid-cols-2">
          <div className="space-y-1.5">
            <label className="text-sm">{t('maintenance.field_frequency', 'Freqüència')}</label>
            <Select
              value={form.frequency}
              onValueChange={(v) => setForm((f) => ({ ...f, frequency: v as MaintenanceFrequency }))}
            >
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {MAINTENANCE_FREQUENCIES.map((freq) => (
                  <SelectItem key={freq} value={freq}>
                    {t(`maintenance.freq_${freq}`, freq)}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
          <div className="space-y-1.5">
            <label className="text-sm">{t('maintenance.field_interval', 'Cada N períodes')}</label>
            <Input
              type="number"
              min={1}
              value={form.interval_count}
              onChange={(e) =>
                setForm((f) => ({ ...f, interval_count: Math.max(1, Number(e.target.value) || 1) }))
              }
            />
          </div>
          <div className="space-y-1.5">
            <label className="text-sm">{t('maintenance.field_timezone', 'Zona horària')}</label>
            <Input
              value={form.timezone}
              onChange={(e) => setForm((f) => ({ ...f, timezone: e.target.value }))}
            />
          </div>
          <div className="space-y-1.5">
            <label className="text-sm">{t('maintenance.field_lead_days', 'Dies d\'avís')}</label>
            <Input
              type="number"
              min={0}
              value={form.lead_days}
              onChange={(e) =>
                setForm((f) => ({ ...f, lead_days: Math.max(0, Number(e.target.value) || 0) }))
              }
            />
          </div>
        </div>
      </div>

      <div className="space-y-2">
        <p className="text-sm font-medium">
          {t('maintenance.plan_checklists', 'Plantilles del pla')}
        </p>
        <div className="rounded-lg border border-dashed border-border bg-muted/30 px-3 py-2 text-xs text-muted-foreground space-y-1">
          <p>
            {t(
              'maintenance.hierarchy_hint',
              'El pla enganxa plantilles publicades. Els punts (ToDo o de revisió) viuen dins de cada plantilla, no al pla.',
            )}
          </p>
          <p>
            <Link to="/field/checklist-templates" className="underline hover:text-foreground">
              {t('maintenance.manage_templates_link', 'Gestionar plantilles de checklist')}
            </Link>
            {' · '}
            <Link to="/field/checklist-points" className="underline hover:text-foreground">
              {t('maintenance.manage_points_link', 'Gestionar punts de revisió')}
            </Link>
          </p>
        </div>
        <p className="text-xs text-muted-foreground">
          {t(
            'maintenance.plan_checklists_help',
            'Només plantilles del tenant amb versió publicada. S\'apliquen en aquest ordre a cada ordre generada.',
          )}
        </p>

        {templates.length === 0 ? (
          <div className="rounded-lg border border-dashed border-border p-3 text-xs text-muted-foreground space-y-2">
            <p>
              {t(
                'maintenance.no_published_templates',
                'No tens cap plantilla publicada. Crea i publica una plantilla de checklist primer.',
              )}
            </p>
            <Link
              to="/field/checklist-templates"
              className="inline-flex text-sm font-medium underline hover:text-foreground"
            >
              {t('maintenance.go_to_templates', 'Anar a plantilles')}
            </Link>
          </div>
        ) : (
          <>
            {templateIds.length > 0 && (
              <ul className="divide-y divide-border rounded-lg border border-border overflow-hidden">
                {templateIds.map((templateId, index) => {
                  const tpl = templatesById.get(templateId)
                  const isReview = tpl?.kind === 'review'
                  return (
                    <li key={templateId} className="flex items-center gap-2 px-3 py-2 bg-card">
                      <span className="text-xs tabular-nums text-muted-foreground">{index + 1}</span>
                      <div className="flex-1 min-w-0">
                        <p className="flex items-center gap-2 truncate text-sm font-medium">
                          <ChecklistKindIcon kind={tpl?.kind ?? 'todo'} />
                          <span className="truncate">{tpl?.name ?? templateId}</span>
                        </p>
                        <div className="mt-0.5 flex flex-wrap items-center gap-1 text-xs text-muted-foreground">
                          {tpl && (
                            <Badge variant="outline" className="text-[10px] font-normal">
                              {isReview
                                ? t('maintenance.kind_review', 'Punts de revisió')
                                : t('maintenance.kind_todo', 'Punts ToDo')}
                            </Badge>
                          )}
                          {tpl && (
                            <span>
                              {t('maintenance.item_count', '{{count}} ítems', {
                                count: tpl.item_count,
                              })}
                              {tpl.version_number != null ? ` · v${tpl.version_number}` : ''}
                            </span>
                          )}
                        </div>
                      </div>
                      <Button
                        size="icon"
                        variant="ghost"
                        disabled={index === 0}
                        onClick={() => move(index, -1)}
                        aria-label={t('maintenance.move_up', 'Amunt')}
                      >
                        <ArrowUp className="h-4 w-4" />
                      </Button>
                      <Button
                        size="icon"
                        variant="ghost"
                        disabled={index === templateIds.length - 1}
                        onClick={() => move(index, 1)}
                        aria-label={t('maintenance.move_down', 'Avall')}
                      >
                        <ArrowDown className="h-4 w-4" />
                      </Button>
                      <Button
                        size="icon"
                        variant="ghost"
                        className="text-destructive"
                        onClick={() =>
                          setTemplateIds((prev) => prev.filter((id) => id !== templateId))
                        }
                        aria-label={t('maintenance.unlink', 'Treure')}
                      >
                        <Trash2 className="h-4 w-4" />
                      </Button>
                    </li>
                  )
                })}
              </ul>
            )}

            {available.length > 0 && (
              <Select value="" onValueChange={(v) => setTemplateIds((prev) => [...prev, v])}>
                <SelectTrigger>
                  <SelectValue
                    placeholder={t('maintenance.add_checklist', 'Afegir una plantilla publicada')}
                  />
                </SelectTrigger>
                <SelectContent>
                  {available.map((tpl) => (
                    <SelectItem key={tpl.id} value={tpl.id}>
                      {tpl.name} ·{' '}
                      {tpl.kind === 'review'
                        ? t('maintenance.kind_review', 'Punts de revisió')
                        : t('maintenance.kind_todo', 'Punts ToDo')}{' '}
                      · v{tpl.version_number}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            )}
          </>
        )}
      </div>

      <div className="flex gap-2">
        <Button onClick={() => void handleSave()} disabled={saving}>
          {saving ? t('templates.saving', 'Desant…') : t('templates.save', 'Desar')}
        </Button>
        <Button variant="ghost" onClick={onClose}>
          {t('templates.cancel', 'Cancel·lar')}
        </Button>
      </div>
    </div>
  )
}

export function MaintenancePlansPage() {
  const { t } = useTranslation('field-service')
  const { toast } = useToast()
  const { activeTenant } = useTenant()
  const queryClient = useQueryClient()
  const tenantId = activeTenant?.id ?? null

  const [tab, setTab] = useState('tenant')
  const [tenantSearch, setTenantSearch] = useState('')
  const [tenantPage, setTenantPage] = useState(1)
  const [platformSearch, setPlatformSearch] = useState('')
  const [platformPage, setPlatformPage] = useState(1)
  const [expandedPlanId, setExpandedPlanId] = useState<string | null>(null)

  const [editorOpen, setEditorOpen] = useState(false)
  const [editingPlan, setEditingPlan] = useState<MaintenancePlan | null>(null)

  const [showAssignForm, setShowAssignForm] = useState(false)
  const [assignPlanId, setAssignPlanId] = useState('')
  const [entityType, setEntityType] = useState<MaintenanceEntityType>('contact_site')
  const [entityId, setEntityId] = useState('')
  const [assignFrequency, setAssignFrequency] = useState<MaintenanceFrequency>('monthly')
  const [assignInterval, setAssignInterval] = useState(1)
  const [nextDueAt, setNextDueAt] = useState('')
  const [savingAssignment, setSavingAssignment] = useState(false)

  const tenantPlansQuery = useQuery({
    queryKey: ['maintenance_tenant_plans', tenantId, tenantSearch, tenantPage],
    queryFn: () =>
      listTenantPlans(tenantId!, { search: tenantSearch, page: tenantPage, pageSize: PAGE_SIZE }),
    enabled: !!tenantId,
  })

  const platformPlansQuery = useQuery({
    queryKey: ['maintenance_platform_plans', platformSearch, platformPage],
    queryFn: () => listPlatformPlans({ search: platformSearch, page: platformPage, pageSize: PAGE_SIZE }),
  })

  const { data: assignments = [] } = useQuery({
    queryKey: ['maintenance_plan_assignments', tenantId],
    queryFn: () => listAssignments(tenantId!),
    enabled: !!tenantId,
  })

  const { data: planUpdates = [] } = useQuery({
    queryKey: ['maintenance_plan_updates', tenantId],
    queryFn: () => listPlanUpdates(tenantId!),
    enabled: !!tenantId,
  })

  const tenantPlans = tenantPlansQuery.data?.rows ?? []
  const platformPlans = platformPlansQuery.data?.rows ?? []
  const hasTenantPlans = tenantPlans.length > 0 || tenantSearch.trim().length > 0
  const canAssign = tenantPlans.length > 0

  const updatesByPlan = useMemo(
    () => new Map(planUpdates.filter((u) => u.update_available).map((u) => [u.tenant_plan_id, u])),
    [planUpdates],
  )
  const plansById = useMemo(
    () => new Map([...tenantPlans, ...platformPlans].map((p) => [p.id, p])),
    [tenantPlans, platformPlans],
  )

  function periodicityLabel(plan: MaintenancePlan): string {
    const freq = t(`maintenance.freq_${plan.frequency}`, plan.frequency)
    const base =
      plan.interval_count > 1
        ? t('maintenance.every_n', 'Cada {{n}} · {{freq}}', { n: plan.interval_count, freq })
        : freq
    if (plan.lead_days > 0) {
      return `${base} · ${t('maintenance.lead_days_short', 'avís {{n}}d', { n: plan.lead_days })}`
    }
    return base
  }

  async function handleClone(plan: MaintenancePlan) {
    if (!tenantId) return
    try {
      const newId = await clonePlan(plan.id, tenantId)
      await queryClient.invalidateQueries({ queryKey: ['maintenance_tenant_plans'] })
      await queryClient.invalidateQueries({ queryKey: ['maintenance_plan_updates'] })
      setTab('tenant')
      const unpublished = await countUnpublishedPlanTemplates(newId).catch(() => 0)
      toast({
        description:
          unpublished > 0
            ? t(
                'maintenance.clone_success_drafts',
                'Pla clonat. Hi ha {{n}} plantilles en esborrany: publica-les abans d\'assignar o generar ordres.',
                { n: unpublished },
              )
            : t('maintenance.clone_success', 'Pla clonat al tenant'),
      })
    } catch (err) {
      const message =
        err instanceof Error && err.message
          ? err.message
          : t('maintenance.clone_failed', 'No s\'ha pogut clonar el pla')
      toast({ variant: 'destructive', description: message })
    }
  }

  async function handleArchive(plan: MaintenancePlan) {
    if (!tenantId) return
    try {
      await archivePlan(plan.id, tenantId)
      await queryClient.invalidateQueries({ queryKey: ['maintenance_tenant_plans'] })
      toast({ description: t('maintenance.archived', 'Pla arxivat') })
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      toast({ variant: 'destructive', description: message })
    }
  }

  async function handleCreateAssignment() {
    if (!tenantId || !assignPlanId) return
    const trimmedEntityId = entityId.trim()
    if (!UUID_RE.test(trimmedEntityId)) {
      toast({
        variant: 'destructive',
        description: t('maintenance.entity_id_invalid', 'L\'ID de l\'entitat ha de ser un UUID'),
      })
      return
    }
    setSavingAssignment(true)
    try {
      const unpublished = await countUnpublishedPlanTemplates(assignPlanId)
      if (unpublished > 0) {
        toast({
          variant: 'destructive',
          description: t(
            'maintenance.assignment_unpublished',
            'Aquest pla té {{n}} plantilles sense publicar. Publica-les abans d\'assignar.',
            { n: unpublished },
          ),
        })
        return
      }
      await createAssignment({
        tenant_id: tenantId,
        plan_id: assignPlanId,
        entity_type: entityType,
        entity_id: trimmedEntityId,
        frequency: assignFrequency,
        interval_count: assignInterval,
        next_due_at: nextDueAt ? new Date(nextDueAt).toISOString() : null,
      })
      await queryClient.invalidateQueries({ queryKey: ['maintenance_plan_assignments'] })
      setShowAssignForm(false)
      setEntityId('')
      setNextDueAt('')
      toast({ description: t('maintenance.assignment_created', 'Assignació creada') })
    } catch (err) {
      const message =
        err instanceof Error && err.message
          ? err.message
          : t('maintenance.assignment_failed', 'No s\'ha pogut crear l\'assignació')
      toast({ variant: 'destructive', description: message })
    } finally {
      setSavingAssignment(false)
    }
  }

  function openEditor(plan: MaintenancePlan | null) {
    setEditingPlan(plan)
    setEditorOpen(true)
  }

  function selectPlanForAssignment(planId: string) {
    setAssignPlanId(planId)
    const plan = plansById.get(planId)
    if (plan) {
      setAssignFrequency(plan.frequency)
      setAssignInterval(plan.interval_count)
    }
  }

  return (
    <div className="mx-auto max-w-5xl space-y-4 px-4 py-6 pb-24">
      <div>
        <Link to="/field/more" className="text-sm text-muted-foreground hover:underline">
          ← {t('more.title', 'Més')}
        </Link>
        <h1 className="mt-1 text-2xl font-bold flex items-center gap-2">
          <CalendarClock className="h-6 w-6" />
          {t('maintenance.title', 'Plans de manteniment')}
        </h1>
        <p className="text-sm text-muted-foreground mt-1">
          {t(
            'maintenance.subtitle',
            'Periodicitat i assignació. El contingut de la visita ve de les plantilles de checklist enganxades al pla.',
          )}
        </p>
      </div>

      {!canAssign && !tenantPlansQuery.isLoading && (
        <div className="rounded-xl border border-amber-300/60 bg-amber-50 p-4 dark:bg-amber-950/30">
          <p className="flex items-center gap-2 text-sm font-medium">
            <AlertTriangle className="h-4 w-4 text-amber-600" />
            {t('maintenance.no_tenant_plans_title', 'Encara no tens cap pla propi')}
          </p>
          <p className="mt-1 text-xs text-muted-foreground">
            {t(
              'maintenance.no_tenant_plans_help',
              'Els plans de la plataforma no es poden assignar directament: cal clonar-los o crear-ne un de nou.',
            )}
          </p>
          <div className="mt-3 flex flex-wrap gap-2">
            <Button size="sm" className="gap-1" onClick={() => openEditor(null)}>
              <Plus className="h-4 w-4" />
              {t('maintenance.cta_create_plan', 'Crear un pla')}
            </Button>
            <Button size="sm" variant="outline" className="gap-1" onClick={() => setTab('platform')}>
              <Copy className="h-4 w-4" />
              {t('maintenance.cta_clone_library', 'Clonar de la biblioteca')}
            </Button>
          </div>
        </div>
      )}

      <div className="flex flex-wrap justify-end gap-2">
        <Button size="sm" variant="outline" className="gap-1" onClick={() => openEditor(null)}>
          <Plus className="h-4 w-4" />
          {t('maintenance.new_plan', 'Nou pla')}
        </Button>
        <Button
          size="sm"
          className="gap-1"
          disabled={!canAssign}
          title={
            canAssign
              ? undefined
              : t('maintenance.assign_disabled', 'Necessites almenys un pla del tenant')
          }
          onClick={() => setShowAssignForm((v) => !v)}
        >
          <Plus className="h-4 w-4" />
          {t('maintenance.new_assignment', 'Nova assignació')}
        </Button>
      </div>

      {editorOpen && tenantId && (
        <PlanEditor
          tenantId={tenantId}
          plan={editingPlan}
          onClose={() => {
            setEditorOpen(false)
            setEditingPlan(null)
          }}
        />
      )}

      {showAssignForm && canAssign && (
        <div className="rounded-xl border border-border p-4 space-y-3">
          <p className="text-sm font-medium">
            {t('maintenance.create_assignment', 'Crear assignació')}
          </p>
          <p className="text-xs text-muted-foreground">
            {t(
              'maintenance.assignment_temp_hint',
              'Temporal: encara no hi ha selector d\'entitats. Enganxa l\'UUID de contacte, site, location, contact_site o asset. Això és provisional fins al selector ric.',
            )}
          </p>
          <Select value={assignPlanId} onValueChange={selectPlanForAssignment}>
            <SelectTrigger>
              <SelectValue placeholder={t('maintenance.pick_plan', 'Tria un pla')} />
            </SelectTrigger>
            <SelectContent>
              {tenantPlans.map((plan) => (
                <SelectItem key={plan.id} value={plan.id}>
                  {plan.name}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
          <Select value={entityType} onValueChange={(v) => setEntityType(v as MaintenanceEntityType)}>
            <SelectTrigger>
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {MAINTENANCE_ENTITY_TYPES.map((et) => (
                <SelectItem key={et} value={et}>
                  {t(`maintenance.entity_${et}`, et)}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
          <Input
            value={entityId}
            onChange={(e) => setEntityId(e.target.value)}
            placeholder={t('maintenance.entity_id', 'ID de l\'entitat (UUID)')}
          />
          <div className="grid gap-2 sm:grid-cols-2">
            <Select
              value={assignFrequency}
              onValueChange={(v) => setAssignFrequency(v as MaintenanceFrequency)}
            >
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {MAINTENANCE_FREQUENCIES.map((freq) => (
                  <SelectItem key={freq} value={freq}>
                    {t(`maintenance.freq_${freq}`, freq)}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <Input
              type="number"
              min={1}
              value={assignInterval}
              onChange={(e) => setAssignInterval(Math.max(1, Number(e.target.value) || 1))}
            />
          </div>
          <Input
            type="datetime-local"
            value={nextDueAt}
            onChange={(e) => setNextDueAt(e.target.value)}
          />
          <Button
            onClick={() => void handleCreateAssignment()}
            disabled={savingAssignment || !assignPlanId || !entityId.trim()}
          >
            {savingAssignment
              ? t('templates.saving', 'Desant…')
              : t('maintenance.create_assignment', 'Crear assignació')}
          </Button>
        </div>
      )}

      <Tabs value={tab} onValueChange={setTab}>
        <TabsList>
          <TabsTrigger value="tenant">{t('maintenance.tenant_plans', 'Plans del tenant')}</TabsTrigger>
          <TabsTrigger value="platform">
            {t('library.title', 'Biblioteca de plataforma')}
          </TabsTrigger>
        </TabsList>

        <TabsContent value="tenant" className="space-y-3">
          <Input
            value={tenantSearch}
            onChange={(e) => {
              setTenantSearch(e.target.value)
              setTenantPage(1)
            }}
            placeholder={t('maintenance.search', 'Cercar per nom o descripció')}
          />

          {tenantPlansQuery.isLoading ? (
            <p className="text-sm text-muted-foreground">{t('templates.loading', 'Carregant…')}</p>
          ) : tenantPlans.length === 0 ? (
            <p className="text-sm text-muted-foreground">
              {hasTenantPlans
                ? t('maintenance.empty_filtered', 'Cap pla amb aquests filtres.')
                : t('maintenance.empty', 'Cap pla de manteniment.')}
            </p>
          ) : (
            <ul className="divide-y divide-border rounded-2xl border border-border overflow-hidden">
              {tenantPlans.map((plan) => {
                const update = updatesByPlan.get(plan.id)
                const expanded = expandedPlanId === plan.id
                return (
                  <li key={plan.id} className="bg-card">
                    <div className="flex items-start gap-2 px-4 py-3">
                      <button
                        type="button"
                        className="mt-0.5 text-muted-foreground"
                        onClick={() => setExpandedPlanId(expanded ? null : plan.id)}
                        aria-label={t('maintenance.toggle_preview', 'Veure contingut')}
                      >
                        {expanded ? (
                          <ChevronDown className="h-4 w-4" />
                        ) : (
                          <ChevronRight className="h-4 w-4" />
                        )}
                      </button>
                      <div className="flex-1 min-w-0">
                        <p className="font-medium flex flex-wrap items-center gap-2">
                          {plan.name}
                          {update && (
                            <Badge
                              variant="secondary"
                              title={t(
                                'maintenance.update_available_hint',
                                'La versió de plataforma «{{name}}» ha canviat (v{{from}} → v{{to}})',
                                {
                                  name: update.source_plan_name,
                                  from: update.source_version_at_fork,
                                  to: update.source_catalog_version,
                                },
                              )}
                            >
                              {t('maintenance.update_available', 'Actualització disponible')}
                            </Badge>
                          )}
                        </p>
                        <p className="text-xs text-muted-foreground">
                          {t('maintenance.checklist_count', '{{count}} checklists', {
                            count: plan.checklists?.length ?? 0,
                          })}
                          {' · '}
                          {periodicityLabel(plan)}
                        </p>
                      </div>
                      <Button
                        size="icon"
                        variant="ghost"
                        onClick={() => openEditor(plan)}
                        aria-label={t('templates.edit', 'Editar')}
                      >
                        <Pencil className="h-4 w-4" />
                      </Button>
                      <Button
                        size="icon"
                        variant="ghost"
                        className="text-destructive"
                        onClick={() => void handleArchive(plan)}
                        aria-label={t('maintenance.archive', 'Arxivar')}
                      >
                        <Trash2 className="h-4 w-4" />
                      </Button>
                    </div>
                    {expanded && (
                      <div className="px-4 pb-3">
                        <PlanContentPreview planId={plan.id} />
                      </div>
                    )}
                  </li>
                )
              })}
            </ul>
          )}

          <Pager
            page={tenantPage}
            total={tenantPlansQuery.data?.total ?? 0}
            hasMore={tenantPlansQuery.data?.hasMore ?? false}
            onChange={setTenantPage}
          />
        </TabsContent>

        <TabsContent value="platform" className="space-y-3">
          <p className="text-xs text-muted-foreground">
            {t(
              'maintenance.platform_help',
              'Els plans de plataforma són de només lectura i no es poden assignar. Clona\'n un per fer-lo teu.',
            )}
          </p>
          <Input
            value={platformSearch}
            onChange={(e) => {
              setPlatformSearch(e.target.value)
              setPlatformPage(1)
            }}
            placeholder={t('maintenance.search', 'Cercar per nom o descripció')}
          />

          {platformPlansQuery.isLoading ? (
            <p className="text-sm text-muted-foreground">{t('templates.loading', 'Carregant…')}</p>
          ) : platformPlans.length === 0 ? (
            <p className="text-sm text-muted-foreground">
              {t('maintenance.library_empty', 'La biblioteca de plataforma és buida.')}
            </p>
          ) : (
            <ul className="divide-y divide-border rounded-2xl border border-border overflow-hidden">
              {platformPlans.map((plan) => {
                const expanded = expandedPlanId === plan.id
                return (
                  <li key={plan.id} className="bg-card">
                    <div className="flex items-start gap-2 px-4 py-3">
                      <button
                        type="button"
                        className="mt-0.5 text-muted-foreground"
                        onClick={() => setExpandedPlanId(expanded ? null : plan.id)}
                        aria-label={t('maintenance.toggle_preview', 'Veure contingut')}
                      >
                        {expanded ? (
                          <ChevronDown className="h-4 w-4" />
                        ) : (
                          <ChevronRight className="h-4 w-4" />
                        )}
                      </button>
                      <div className="flex-1 min-w-0">
                        <p className="font-medium flex flex-wrap items-center gap-2">
                          {plan.name}
                          <Badge variant="secondary">{t('library.platform', 'Plataforma')}</Badge>
                        </p>
                        <p className="text-xs text-muted-foreground">
                          {t('maintenance.checklist_count', '{{count}} checklists', {
                            count: plan.checklists?.length ?? 0,
                          })}
                          {' · '}
                          {periodicityLabel(plan)}
                          {' · '}
                          {plan.category}
                        </p>
                      </div>
                      <Button
                        size="sm"
                        variant="outline"
                        className="gap-1 shrink-0"
                        onClick={() => void handleClone(plan)}
                      >
                        <Copy className="h-4 w-4" />
                        {t('library.clone_edit', 'Clonar i editar')}
                      </Button>
                    </div>
                    {expanded && (
                      <div className="px-4 pb-3">
                        <PlanContentPreview planId={plan.id} />
                      </div>
                    )}
                  </li>
                )
              })}
            </ul>
          )}

          <Pager
            page={platformPage}
            total={platformPlansQuery.data?.total ?? 0}
            hasMore={platformPlansQuery.data?.hasMore ?? false}
            onChange={setPlatformPage}
          />
        </TabsContent>
      </Tabs>

      {assignments.length > 0 && (
        <section className="space-y-2">
          <h2 className="text-sm font-semibold">{t('maintenance.assignments', 'Assignacions')}</h2>
          <ul className="divide-y divide-border rounded-2xl border border-border overflow-hidden">
            {assignments.map((assignment) => {
              const plan = plansById.get(assignment.plan_id)
              return (
                <li key={assignment.id} className="px-4 py-3 text-sm bg-card">
                  <p className="font-medium">{plan?.name ?? assignment.plan_id}</p>
                  <p className="text-xs text-muted-foreground">
                    {t(`maintenance.entity_${assignment.entity_type}`, assignment.entity_type)}
                    {' · '}
                    {assignment.entity_id.slice(0, 8)}…
                    {' · '}
                    {t(`maintenance.freq_${assignment.frequency}`, assignment.frequency)}
                    {assignment.next_due_at &&
                      ` · ${new Date(assignment.next_due_at).toLocaleDateString()}`}
                  </p>
                </li>
              )
            })}
          </ul>
        </section>
      )}
    </div>
  )
}

function Pager({
  page,
  total,
  hasMore,
  onChange,
}: {
  page: number
  total: number
  hasMore: boolean
  onChange: (page: number) => void
}) {
  const { t } = useTranslation('field-service')
  if (total <= PAGE_SIZE) return null

  return (
    <div className="flex items-center justify-between text-xs text-muted-foreground">
      <Button size="sm" variant="ghost" disabled={page <= 1} onClick={() => onChange(page - 1)}>
        {t('maintenance.prev_page', 'Anterior')}
      </Button>
      <span>
        {t('maintenance.page_of', 'Pàgina {{page}} de {{pages}}', {
          page,
          pages: Math.max(1, Math.ceil(total / PAGE_SIZE)),
        })}
      </span>
      <Button size="sm" variant="ghost" disabled={!hasMore} onClick={() => onChange(page + 1)}>
        {t('maintenance.next_page', 'Següent')}
      </Button>
    </div>
  )
}
