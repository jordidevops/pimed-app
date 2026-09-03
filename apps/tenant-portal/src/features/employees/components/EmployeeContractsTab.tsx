import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { FileText, Loader2, PenLine, Plus, RefreshCw } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import {
  useCreateEmploymentContract,
  useCreateEmploymentContractRenewal,
  useEffectiveEmploymentContract,
  useEmployeeContractTerms,
  useEmployeeWorkContext,
  useEmploymentContractAlerts,
  useEmploymentContractTypes,
  useEmploymentContracts,
  useGenerateEmploymentContractDocument,
  useReconcileEmploymentContracts,
  useStartEmploymentContractSigning,
  useTransitionEmploymentContract,
  useUpdateEmploymentContract,
} from '../api/useEmploymentContracts'
import {
  DEFAULT_EMPLOYMENT_CONTRACT_TEMPLATE_LOCALE_ID,
  isOverlapError,
  type ContractLifecycleStatus,
  type EmploymentContract,
} from '../api/employmentContractsService'
import { useCalendarGroups } from '@/features/attendance/api/useLaborCalendar'
import { useEmployee } from '../api/useEmployee'

function todayIso() {
  return new Date().toISOString().slice(0, 10)
}

function statusBadgeClass(status: string | null | undefined) {
  switch (status) {
    case 'active':
      return 'bg-emerald-100 text-emerald-800'
    case 'scheduled':
      return 'bg-sky-100 text-sky-800'
    case 'draft':
      return 'bg-amber-100 text-amber-900'
    case 'ended':
      return 'bg-slate-100 text-slate-700'
    case 'cancelled':
      return 'bg-rose-100 text-rose-800'
    default:
      return 'bg-muted text-muted-foreground'
  }
}

function signatureBadgeClass(status: string | null | undefined) {
  switch (status) {
    case 'completed':
      return 'bg-emerald-100 text-emerald-800'
    case 'pending':
    case 'partial':
      return 'bg-sky-100 text-sky-800'
    case 'rejected':
    case 'expired':
      return 'bg-rose-100 text-rose-800'
    default:
      return 'bg-muted text-muted-foreground'
  }
}

function shortId(id: string | null | undefined): string {
  if (!id) return '—'
  return id.length > 8 ? `${id.slice(0, 8)}…` : id
}

function asRecord(v: unknown): Record<string, unknown> | null {
  return v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, unknown>) : null
}

function WorkContextPanel({ ctx }: { ctx: Record<string, unknown> }) {
  const { t } = useTranslation('employees')
  const convenio = asRecord(ctx.convenio_categoria)
  const workload = asRecord(ctx.workload)
  const placement = asRecord(ctx.placement)
  const leave = asRecord(ctx.leave_terms)
  const conflicts = Array.isArray(ctx.conflicts) ? ctx.conflicts : []

  const caName = convenio?.collective_agreement_name
    ? String(convenio.collective_agreement_name)
    : null
  const caCode = convenio?.collective_agreement_code
    ? String(convenio.collective_agreement_code)
    : null
  const pcName = convenio?.professional_category_name
    ? String(convenio.professional_category_name)
    : null
  const pcCode = convenio?.professional_category_code
    ? String(convenio.professional_category_code)
    : null

  const weeklyHours = workload?.weekly_hours != null ? Number(workload.weekly_hours) : null
  const basis = workload?.commitment_basis ? String(workload.commitment_basis) : null
  const ordinary =
    workload?.ordinary_commitment_minutes != null
      ? Number(workload.ordinary_commitment_minutes)
      : null
  const complementary =
    workload?.complementary_commitment_minutes != null
      ? Number(workload.complementary_commitment_minutes)
      : null
  const wlSource = workload?.source ? String(workload.source) : null
  const siteId = placement?.site_id ? String(placement.site_id) : null
  const plSource = placement?.source ? String(placement.source) : null

  const leaveSummary =
    leave && leave.note
      ? String(leave.note)
      : leave
        ? [
            leave.paid_leave_allowance != null ? String(leave.paid_leave_allowance) : null,
            leave.allowance_unit ? String(leave.allowance_unit) : null,
            leave.counting_method ? String(leave.counting_method) : null,
          ]
            .filter(Boolean)
            .join(' · ') || null
        : null

  return (
    <div className="mt-3 rounded-lg border px-3 py-2 text-xs space-y-1.5">
      <p className="font-medium text-foreground">
        {t('employees.contracts.work_context_title', 'Context de treball efectiu')}
        {ctx.resolver_version ? (
          <span className="ml-2 font-normal text-muted-foreground">
            {String(ctx.resolver_version)}
          </span>
        ) : null}
      </p>
      <p className="text-muted-foreground">
        {t('employees.contracts.work_context_convenio', 'Conveni / categoria')}
        {': '}
        <span className="text-foreground">
          {caName || caCode
            ? `${caName ?? '—'}${caCode ? ` (${caCode})` : ''}`
            : t('employees.contracts.work_context_none', '—')}
          {' · '}
          {pcName || pcCode
            ? `${pcName ?? '—'}${pcCode ? ` (${pcCode})` : ''}`
            : t('employees.contracts.work_context_none', '—')}
        </span>
      </p>
      <p className="text-muted-foreground">
        {t('employees.contracts.work_context_workload', 'Càrrega')}
        {': '}
        <span className="text-foreground">
          {weeklyHours != null ? `${weeklyHours} h` : '—'}
          {basis ? ` · ${basis}` : ''}
          {ordinary != null ? ` · ${ordinary} min ord.` : ''}
          {complementary != null ? ` · ${complementary} min comp.` : ''}
          {wlSource ? ` · ${wlSource}` : ''}
        </span>
      </p>
      <p className="text-muted-foreground">
        {t('employees.contracts.work_context_placement', 'Ubicació')}
        {': '}
        <span className="text-foreground">
          {shortId(siteId)}
          {plSource ? ` · ${plSource}` : ''}
        </span>
      </p>
      {leaveSummary ? (
        <p className="text-muted-foreground">
          {t('employees.contracts.work_context_leave', 'Vacances / permisos')}
          {': '}
          <span className="text-foreground">{leaveSummary}</span>
        </p>
      ) : null}
      {conflicts.length > 0 ? (
        <div>
          <p className="font-medium text-amber-800">
            {t('employees.contracts.work_context_conflicts', 'Conflictes')} ({conflicts.length})
          </p>
          <ul className="mt-0.5 space-y-0.5 text-amber-900">
            {conflicts.slice(0, 6).map((c, i) => {
              const row = asRecord(c)
              const dim = row?.dimension ? String(row.dimension) : `conflict-${i}`
              return (
                <li key={`${dim}-${i}`}>
                  {dim}
                  {row?.contract != null ? ` · contracte: ${String(row.contract)}` : ''}
                  {row?.employee_flat != null ? ` · pla: ${String(row.employee_flat)}` : ''}
                  {row?.workload_terms != null
                    ? ` · workload: ${String(row.workload_terms)}`
                    : ''}
                </li>
              )
            })}
          </ul>
        </div>
      ) : null}
    </div>
  )
}

export function EmployeeContractsTab({
  employeeId,
  canView,
  canManage,
}: {
  employeeId: string
  canView: boolean
  canManage: boolean
}) {
  const { t } = useTranslation('employees')
  const { toast } = useToast()
  const { activeTenant } = useTenant()
  const { data: contracts = [], isLoading } = useEmploymentContracts(canView ? employeeId : undefined)
  const { data: effective } = useEffectiveEmploymentContract(canView ? employeeId : undefined)
  const { data: terms } = useEmployeeContractTerms(canView ? employeeId : undefined)
  const { data: workContext } = useEmployeeWorkContext(canView ? employeeId : undefined)
  const { data: employee } = useEmployee(employeeId)
  const { data: calendarGroups = [] } = useCalendarGroups(employee?.site_id ?? null)
  const { data: types = [] } = useEmploymentContractTypes(true)
  const create = useCreateEmploymentContract(employeeId)
  const renew = useCreateEmploymentContractRenewal(employeeId)
  const update = useUpdateEmploymentContract(employeeId)
  const transition = useTransitionEmploymentContract(employeeId)
  const reconcile = useReconcileEmploymentContracts(employeeId)
  const generateDoc = useGenerateEmploymentContractDocument(employeeId)
  const startSigning = useStartEmploymentContractSigning(employeeId)
  const { data: alertsReport } = useEmploymentContractAlerts(canView ? employeeId : undefined)

  const [showForm, setShowForm] = useState(false)
  const [editingId, setEditingId] = useState<string | null>(null)
  const [startsOn, setStartsOn] = useState(todayIso())
  const [endsOn, setEndsOn] = useState('')
  const [weeklyHours, setWeeklyHours] = useState('40')
  const [contractNumber, setContractNumber] = useState('')
  const [contractTypeId, setContractTypeId] = useState('')
  const [calendarGroupId, setCalendarGroupId] = useState('')
  const [busyId, setBusyId] = useState<string | null>(null)

  const typeNameById = useMemo(() => {
    const m = new Map<string, string>()
    for (const ty of types) {
      if (ty.id) m.set(ty.id, ty.name ?? ty.id)
    }
    return m
  }, [types])

  const groupNameById = useMemo(() => {
    const m = new Map<string, string>()
    for (const g of calendarGroups) {
      if (g.id) m.set(g.id, g.name ?? g.id)
    }
    return m
  }, [calendarGroups])

  const grouped = useMemo(() => {
    const current: EmploymentContract[] = []
    const future: EmploymentContract[] = []
    const history: EmploymentContract[] = []
    const drafts: EmploymentContract[] = []
    const today = todayIso()
    for (const c of contracts) {
      const st = c.lifecycle_status
      if (st === 'draft') drafts.push(c)
      else if (st === 'cancelled' || st === 'ended') history.push(c)
      else if (st === 'scheduled' && c.starts_on && c.starts_on > today) future.push(c)
      else current.push(c)
    }
    return { current, future, history, drafts }
  }, [contracts])

  function resetForm(seed?: EmploymentContract) {
    setEditingId(seed?.id ?? null)
    setStartsOn(seed?.starts_on ?? todayIso())
    setEndsOn(seed?.ends_on ?? '')
    setWeeklyHours(seed?.weekly_hours != null ? String(seed.weekly_hours) : '40')
    setContractNumber(seed?.contract_number ?? '')
    setContractTypeId(seed?.contract_type_id ?? '')
    setCalendarGroupId(seed?.calendar_group_id ?? '')
    setShowForm(true)
  }

  async function onSave() {
    if (!activeTenant?.id || !startsOn) return
    try {
      const payload = {
        starts_on: startsOn,
        ends_on: endsOn || null,
        weekly_hours: weeklyHours ? Number(weeklyHours) : null,
        contract_number: contractNumber.trim() || null,
        contract_type_id: contractTypeId || null,
        calendar_group_id: calendarGroupId || null,
        is_primary: true,
        signature_requirement: 'none' as const,
        signature_status: 'not_required' as const,
      }
      if (editingId) {
        await update.mutateAsync({ id: editingId, patch: payload })
        toast({ title: t('employees.contracts.updated', 'Contracte actualitzat') })
      } else {
        await create.mutateAsync({
          ...payload,
          lifecycle_status: 'draft',
          approval_status: 'not_required',
        })
        toast({ title: t('employees.contracts.created', 'Contracte creat') })
      }
      setShowForm(false)
      setEditingId(null)
    } catch (e) {
      toast({
        variant: 'destructive',
        title: isOverlapError(e)
          ? t('employees.contracts.overlap_error', 'Solapament amb un altre contracte principal')
          : t('employees.contracts.save_failed', "No s'ha pogut desar el contracte"),
        description: e instanceof Error ? e.message : undefined,
      })
    }
  }

  async function onTransition(c: EmploymentContract, to: ContractLifecycleStatus) {
    if (!c.id) return
    setBusyId(c.id)
    try {
      await transition.mutateAsync({ contractId: c.id, toStatus: to })
      toast({
        title: t('employees.contracts.transitioned', 'Estat actualitzat'),
        description: to,
      })
    } catch (e) {
      toast({
        variant: 'destructive',
        title: isOverlapError(e)
          ? t('employees.contracts.overlap_error', 'Solapament amb un altre contracte principal')
          : t('employees.contracts.transition_failed', "No s'ha pogut canviar l'estat"),
        description: e instanceof Error ? e.message : undefined,
      })
    } finally {
      setBusyId(null)
    }
  }

  async function onRenew(c: EmploymentContract) {
    if (!c.id) return
    try {
      await renew.mutateAsync(c.id)
      toast({ title: t('employees.contracts.renewed', 'Esborrany de renovació creat') })
    } catch (e) {
      toast({
        variant: 'destructive',
        title: t('employees.contracts.save_failed', "No s'ha pogut desar el contracte"),
        description: e instanceof Error ? e.message : undefined,
      })
    }
  }

  async function onGenerateDocument(c: EmploymentContract, force = false) {
    if (!c.id) return
    setBusyId(c.id)
    try {
      const out = await generateDoc.mutateAsync({
        contractId: c.id,
        templateLocaleId: c.template_locale_id ?? DEFAULT_EMPLOYMENT_CONTRACT_TEMPLATE_LOCALE_ID,
        force,
      })
      toast({
        title: force
          ? t('employees.contracts.doc_regenerated', 'Document regenerat')
          : t('employees.contracts.doc_generated', 'Document generat'),
        description: out.generated_document_id
          ? t('employees.contracts.doc_ready', 'Ja el pots obrir al DMS')
          : undefined,
      })
    } catch (e) {
      toast({
        variant: 'destructive',
        title: t('employees.contracts.doc_failed', "No s'ha pogut generar el document"),
        description: e instanceof Error ? e.message : undefined,
      })
    } finally {
      setBusyId(null)
    }
  }

  async function onSendForSigning(c: EmploymentContract) {
    if (!c.id) return
    setBusyId(c.id)
    try {
      const result = await startSigning.mutateAsync(c.id)
      toast({
        title: t('employees.contracts.signing_started', 'Firma iniciada'),
        description: t(
          'employees.contracts.signing_started_hint',
          'S\'ha enviat al treballador i a RRHH (seqüencial).',
        ),
      })
      if (result.submission_id) {
        // navigation via link rendered after invalidate
      }
    } catch (e) {
      toast({
        variant: 'destructive',
        title: t('employees.contracts.signing_failed', "No s'ha pogut iniciar la firma"),
        description: e instanceof Error ? e.message : undefined,
      })
    } finally {
      setBusyId(null)
    }
  }

  if (!canView) {
    return (
      <p className="text-sm text-muted-foreground">
        {t('employees.contracts.no_permission', 'No tens permís per veure contractes.')}
      </p>
    )
  }

  if (isLoading) {
    return (
      <div className="flex items-center gap-2 text-sm text-muted-foreground py-8">
        <Loader2 className="h-4 w-4 animate-spin" />
        {t('employees.detail.loading', 'Carregant...')}
      </div>
    )
  }

  function renderRow(c: EmploymentContract) {
    const st = c.lifecycle_status ?? 'draft'
    const isBusy = busyId === c.id
    return (
      <li key={c.id!} className="rounded-lg border px-3 py-3 space-y-2">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <div className="min-w-0">
            <div className="flex flex-wrap items-center gap-2">
              <span className={`text-xs px-2 py-0.5 rounded ${statusBadgeClass(st)}`}>
                {t(`employees.contracts.status.${st}`, st)}
              </span>
              {effective?.id === c.id ? (
                <span className="text-xs text-emerald-700 font-medium">
                  {t('employees.contracts.effective_badge', 'Efectiu avui')}
                </span>
              ) : null}
              {c.is_primary ? (
                <span className="text-xs text-muted-foreground">
                  {t('employees.contracts.primary', 'Principal')}
                </span>
              ) : null}
              {c.signature_requirement && c.signature_requirement !== 'none' ? (
                <span className={`text-xs px-2 py-0.5 rounded ${signatureBadgeClass(c.signature_status)}`}>
                  {t(
                    `employees.contracts.sig_status.${c.signature_status ?? 'pending'}`,
                    c.signature_status ?? 'pending',
                  )}
                </span>
              ) : null}
            </div>
            <p className="text-sm mt-1">
              {c.starts_on}
              {c.ends_on ? ` → ${c.ends_on}` : ` → ${t('employees.contracts.open_ended', 'indefinit')}`}
              {c.weekly_hours != null ? ` · ${c.weekly_hours} h` : null}
              {c.calendar_group_id
                ? ` · ${groupNameById.get(c.calendar_group_id) ?? t('employees.contracts.calendar_group', 'Grup')}`
                : null}
              {c.contract_type_id
                ? ` · ${typeNameById.get(c.contract_type_id) ?? c.contract_type_id}`
                : null}
              {c.contract_number ? ` · #${c.contract_number}` : null}
            </p>
            {c.generated_document_id ? (
              <p className="text-xs mt-1">
                <Link
                  to={`/documents/${c.generated_document_id}`}
                  className="text-primary hover:underline inline-flex items-center gap-1"
                >
                  <FileText className="h-3 w-3" />
                  {t('employees.contracts.open_document', 'Obrir document DMS')}
                </Link>
              </p>
            ) : null}
            {c.signing_submission_id ? (
              <p className="text-xs mt-1">
                <Link
                  to={`/documents/signing/${c.signing_submission_id}`}
                  className="text-primary hover:underline inline-flex items-center gap-1"
                >
                  <PenLine className="h-3 w-3" />
                  {t('employees.contracts.open_signing', 'Obrir procés de firma')}
                </Link>
              </p>
            ) : null}
          </div>
          {canManage ? (
            <div className="flex flex-wrap gap-1">
              {st === 'draft' &&
              c.signature_status !== 'completed' &&
              c.signature_status !== 'partial' ? (
                <Button
                  type="button"
                  size="sm"
                  variant="default"
                  disabled={isBusy || startSigning.isPending}
                  onClick={() => void onSendForSigning(c)}
                >
                  {isBusy && startSigning.isPending ? (
                    <Loader2 className="h-3 w-3 animate-spin mr-1" />
                  ) : (
                    <PenLine className="h-3 w-3 mr-1" />
                  )}
                  {c.signing_submission_id
                    ? t('employees.contracts.resign', 'Reenviar firma')
                    : t('employees.contracts.send_signing', 'Enviar a firmar')}
                </Button>
              ) : null}
              {st !== 'cancelled' && c.signature_status !== 'completed' && c.signature_status !== 'partial' ? (
                <Button
                  type="button"
                  size="sm"
                  variant="outline"
                  disabled={isBusy || generateDoc.isPending}
                  onClick={() => void onGenerateDocument(c, !!c.generated_document_id)}
                >
                  {isBusy && generateDoc.isPending ? (
                    <Loader2 className="h-3 w-3 animate-spin mr-1" />
                  ) : (
                    <FileText className="h-3 w-3 mr-1" />
                  )}
                  {c.generated_document_id
                    ? t('employees.contracts.regenerate', 'Regenerar doc')
                    : t('employees.contracts.generate', 'Generar document')}
                </Button>
              ) : null}
              {st === 'draft' ? (
                <>
                  <Button type="button" size="sm" variant="outline" disabled={isBusy} onClick={() => resetForm(c)}>
                    {t('employees.contracts.edit', 'Editar')}
                  </Button>
                  <Button
                    type="button"
                    size="sm"
                    disabled={isBusy || transition.isPending}
                    onClick={() => void onTransition(c, 'scheduled')}
                  >
                    {isBusy ? <Loader2 className="h-3 w-3 animate-spin" /> : null}
                    {t('employees.contracts.schedule', 'Programar')}
                  </Button>
                  <Button
                    type="button"
                    size="sm"
                    variant="ghost"
                    disabled={isBusy}
                    onClick={() => void onTransition(c, 'cancelled')}
                  >
                    {t('employees.contracts.cancel', 'Cancel·lar')}
                  </Button>
                </>
              ) : null}
              {st === 'scheduled' ? (
                <>
                  <Button
                    type="button"
                    size="sm"
                    disabled={isBusy}
                    onClick={() => void onTransition(c, 'active')}
                  >
                    {t('employees.contracts.activate', 'Activar')}
                  </Button>
                  <Button
                    type="button"
                    size="sm"
                    variant="ghost"
                    disabled={isBusy}
                    onClick={() => void onTransition(c, 'cancelled')}
                  >
                    {t('employees.contracts.cancel', 'Cancel·lar')}
                  </Button>
                </>
              ) : null}
              {st === 'active' ? (
                <>
                  <Button
                    type="button"
                    size="sm"
                    variant="outline"
                    disabled={isBusy}
                    onClick={() => void onTransition(c, 'ended')}
                  >
                    {t('employees.contracts.end', 'Finalitzar')}
                  </Button>
                  <Button type="button" size="sm" variant="ghost" onClick={() => void onRenew(c)}>
                    {t('employees.contracts.renew', 'Renovar')}
                  </Button>
                </>
              ) : null}
              {st === 'ended' ? (
                <Button type="button" size="sm" variant="ghost" onClick={() => void onRenew(c)}>
                  {t('employees.contracts.renew', 'Renovar')}
                </Button>
              ) : null}
            </div>
          ) : null}
        </div>
      </li>
    )
  }

  function section(title: string, rows: EmploymentContract[]) {
    if (rows.length === 0) return null
    return (
      <div className="space-y-2">
        <h4 className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">{title}</h4>
        <ul className="space-y-2">{rows.map(renderRow)}</ul>
      </div>
    )
  }

  return (
    <div className="space-y-6 max-w-3xl">
      {alertsReport && alertsReport.count > 0 ? (
        <div className="rounded-lg border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-950">
          <p className="font-medium">
            {t('employees.contracts.alerts_title', 'Alertes contractuals')} ({alertsReport.count})
          </p>
          <ul className="mt-1 space-y-0.5 text-xs">
            {alertsReport.alerts.slice(0, 6).map((a, i) => (
              <li key={`${a.contract_id}-${a.kind}-${i}`}>
                {a.kind === 'activation_blocked'
                  ? t('employees.contracts.alert_blocked', 'Activació bloquejada')
                  : a.kind === 'pending_signature'
                    ? t('employees.contracts.alert_signature', 'Firma pendent')
                    : a.kind === 'starting_soon'
                      ? t('employees.contracts.alert_starting', 'Inici proper')
                      : a.kind === 'expiring_soon'
                        ? t('employees.contracts.alert_expiring', 'Venciment proper')
                        : a.kind}
                {a.ends_on ? ` · ${a.ends_on}` : a.starts_on ? ` · ${a.starts_on}` : ''}
                {a.days_left != null ? ` (${a.days_left}d)` : ''}
              </li>
            ))}
          </ul>
        </div>
      ) : null}
      <div className="flex flex-wrap items-start justify-between gap-2" data-testid="employee-contracts">
        <div>
          <h3 className="text-sm font-semibold">
            {t('employees.contracts.tab_title', 'Contractes laborals')}
          </h3>
          <p className="text-xs text-muted-foreground">
            {t(
              'employees.contracts.tab_hint',
              'Historial temporal. En activar, el grup de calendari i les hores es projecten a l\'empleat (driver d\'assistència).',
            )}
          </p>
          {terms ? (
            <p className="text-xs mt-2 text-muted-foreground">
              {t('employees.contracts.terms_today', 'Termes avui')}
              {': '}
              <span className="text-foreground">
                {terms.weekly_hours != null ? `${terms.weekly_hours} h` : '—'}
                {terms.calendar_group_id
                  ? ` · ${groupNameById.get(terms.calendar_group_id) ?? terms.calendar_group_id}`
                  : ''}
                {' · '}
                {terms.source === 'employment_contract'
                  ? t('employees.contracts.terms_from_contract', 'des del contracte')
                  : t('employees.contracts.terms_from_employee', 'fallback empleat')}
              </span>
            </p>
          ) : null}
          {workContext ? (
            <WorkContextPanel ctx={workContext} />
          ) : null}
        </div>
        {canManage ? (
          <div className="flex gap-2">
            <Button
              type="button"
              size="sm"
              variant="outline"
              disabled={reconcile.isPending}
              onClick={async () => {
                try {
                  const n = await reconcile.mutateAsync()
                  toast({
                    title: t('employees.contracts.reconciled', 'Reconciliat'),
                    description: t('employees.contracts.reconciled_n', '{{n}} canvis', { n }),
                  })
                } catch (e) {
                  toast({
                    variant: 'destructive',
                    title: t('employees.contracts.reconcile_failed', 'Error de reconciliació'),
                    description: e instanceof Error ? e.message : undefined,
                  })
                }
              }}
            >
              {reconcile.isPending ? (
                <Loader2 className="h-4 w-4 animate-spin mr-1" />
              ) : (
                <RefreshCw className="h-4 w-4 mr-1" />
              )}
              {t('employees.contracts.reconcile', 'Reconciliar')}
            </Button>
            <Button
              type="button"
              size="sm"
              onClick={() => {
                setEditingId(null)
                resetForm()
              }}
            >
              <Plus className="h-4 w-4 mr-1" />
              {t('employees.contracts.new', 'Nou contracte')}
            </Button>
          </div>
        ) : null}
      </div>

      {showForm && canManage ? (
        <div className="rounded-lg border p-4 space-y-3">
          <h4 className="text-sm font-medium">
            {editingId
              ? t('employees.contracts.edit_title', 'Editar esborrany')
              : t('employees.contracts.new_title', 'Nou esborrany')}
          </h4>
          <div className="grid gap-3 sm:grid-cols-2">
            <div className="space-y-1">
              <Label htmlFor="ec-starts">{t('employees.contracts.starts_on', 'Inici')}</Label>
              <Input id="ec-starts" type="date" value={startsOn} onChange={(e) => setStartsOn(e.target.value)} />
            </div>
            <div className="space-y-1">
              <Label htmlFor="ec-ends">{t('employees.contracts.ends_on', 'Fi (opcional)')}</Label>
              <Input id="ec-ends" type="date" value={endsOn} onChange={(e) => setEndsOn(e.target.value)} />
            </div>
            <div className="space-y-1">
              <Label htmlFor="ec-hours">{t('employees.contracts.weekly_hours', 'Hores setmanals')}</Label>
              <Input
                id="ec-hours"
                type="number"
                min={0}
                step={0.5}
                value={weeklyHours}
                onChange={(e) => setWeeklyHours(e.target.value)}
              />
            </div>
            <div className="space-y-1">
              <Label htmlFor="ec-number">{t('employees.contracts.number', 'Número')}</Label>
              <Input
                id="ec-number"
                value={contractNumber}
                onChange={(e) => setContractNumber(e.target.value)}
                placeholder="EC-2026-001"
              />
            </div>
            <div className="space-y-1 sm:col-span-2">
              <Label htmlFor="ec-type">{t('employees.contracts.type', 'Tipus')}</Label>
              <select
                id="ec-type"
                className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
                value={contractTypeId}
                onChange={(e) => setContractTypeId(e.target.value)}
              >
                <option value="">{t('employees.contracts.type_none', 'Sense tipus')}</option>
                {types.map((ty) => (
                  <option key={ty.id!} value={ty.id!}>
                    {ty.name}
                  </option>
                ))}
              </select>
            </div>
            <div className="space-y-1 sm:col-span-2">
              <Label htmlFor="ec-cal-group">
                {t('employees.contracts.calendar_group', 'Grup de calendari')}
              </Label>
              <select
                id="ec-cal-group"
                className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
                value={calendarGroupId}
                onChange={(e) => setCalendarGroupId(e.target.value)}
              >
                <option value="">
                  {t('employees.contracts.calendar_group_none', 'Sense canvi / sense grup')}
                </option>
                {calendarGroups.map((g) => (
                  <option key={g.id} value={g.id}>
                    {g.name}
                  </option>
                ))}
              </select>
              <p className="text-xs text-muted-foreground">
                {t(
                  'employees.contracts.calendar_group_hint',
                  'En activar el contracte, s\'assigna a l\'empleat i alimenta el calendari laboral.',
                )}
              </p>
            </div>
          </div>
          <div className="flex gap-2">
            <Button
              type="button"
              size="sm"
              disabled={!startsOn || create.isPending || update.isPending}
              onClick={() => void onSave()}
            >
              {(create.isPending || update.isPending) && (
                <Loader2 className="h-4 w-4 animate-spin mr-1" />
              )}
              {t('employees.contracts.save', 'Desar')}
            </Button>
            <Button type="button" size="sm" variant="ghost" onClick={() => setShowForm(false)}>
              {t('employees.contracts.dismiss', 'Tancar')}
            </Button>
          </div>
        </div>
      ) : null}

      {contracts.length === 0 && !showForm ? (
        <p className="text-sm text-muted-foreground">
          {t('employees.contracts.empty', 'Encara no hi ha contractes per a aquest empleat.')}
        </p>
      ) : (
        <div className="space-y-5">
          {section(t('employees.contracts.section_drafts', 'Esborranys'), grouped.drafts)}
          {section(t('employees.contracts.section_current', 'Vigents / en curs'), grouped.current)}
          {section(t('employees.contracts.section_future', 'Futurs'), grouped.future)}
          {section(t('employees.contracts.section_history', 'Històric'), grouped.history)}
        </div>
      )}
    </div>
  )
}
