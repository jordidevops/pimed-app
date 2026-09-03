import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Loader2, Plus, ShieldCheck } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useToast } from '@/hooks/use-toast'
import { usePermission } from '@/hooks/usePermission'
import {
  useComplianceRequirementRules,
  useComplianceRequirementTypes,
  useUpsertComplianceRequirementRule,
  useUpsertComplianceRequirementType,
  type ComplianceRequirementType,
} from '../api/useComplianceCatalog'
import { EmployeesComplianceDashboard } from './EmployeesComplianceDashboard'

const TYPE_CATEGORIES = ['legal', 'medical', 'technical', 'other'] as const

export function EmployeesComplianceCatalogTab() {
  const { t } = useTranslation('employees')
  const { toast } = useToast()
  const canManage = usePermission('compliance.requirements.manage', null)

  const { data: types = [], isLoading: typesLoading, error: typesError } =
    useComplianceRequirementTypes()
  const { data: rules = [], isLoading: rulesLoading, error: rulesError } =
    useComplianceRequirementRules()

  const upsertType = useUpsertComplianceRequirementType()
  const upsertRule = useUpsertComplianceRequirementRule()

  const [typeDialogOpen, setTypeDialogOpen] = useState(false)
  const [ruleDialogOpen, setRuleDialogOpen] = useState(false)

  const [typeCode, setTypeCode] = useState('')
  const [typeName, setTypeName] = useState('')
  const [typeCategory, setTypeCategory] =
    useState<ComplianceRequirementType['category']>('legal')
  const [typeValidityMonths, setTypeValidityMonths] = useState('')

  const [ruleTypeId, setRuleTypeId] = useState('')
  const [ruleGraceDays, setRuleGraceDays] = useState('0')
  const [ruleBlocking, setRuleBlocking] = useState(true)

  const typeMap = useMemo(() => {
    const map = new Map<string, ComplianceRequirementType>()
    for (const row of types) map.set(row.id, row)
    return map
  }, [types])

  const isLoading = typesLoading || rulesLoading
  const error = typesError ?? rulesError

  function resetTypeForm() {
    setTypeCode('')
    setTypeName('')
    setTypeCategory('legal')
    setTypeValidityMonths('')
  }

  function resetRuleForm() {
    setRuleTypeId(types[0]?.id ?? '')
    setRuleGraceDays('0')
    setRuleBlocking(true)
  }

  async function handleCreateType() {
    const code = typeCode.trim()
    const name = typeName.trim()
    if (!code || !name) {
      toast({
        variant: 'destructive',
        title: t('employees.compliance.errors.required_fields', 'Omple els camps obligatoris'),
      })
      return
    }

    try {
      await upsertType.mutateAsync({
        code,
        name,
        category: typeCategory,
        default_validity_months: typeValidityMonths ? Number(typeValidityMonths) : null,
      })
      toast({ title: t('employees.compliance.type_saved', 'Tipus de requeriment creat') })
      setTypeDialogOpen(false)
      resetTypeForm()
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('employees.compliance.errors.save_failed', "No s'ha pogut desar"),
        description: err instanceof Error ? err.message : undefined,
      })
    }
  }

  async function handleCreateRule() {
    if (!ruleTypeId) {
      toast({
        variant: 'destructive',
        title: t('employees.compliance.errors.required_fields', 'Omple els camps obligatoris'),
      })
      return
    }

    try {
      await upsertRule.mutateAsync({
        requirement_type_id: ruleTypeId,
        scope_type: 'tenant',
        is_blocking: ruleBlocking,
        grace_period_days: Number(ruleGraceDays) || 0,
      })
      toast({ title: t('employees.compliance.rule_saved', 'Regla de compliment creada') })
      setRuleDialogOpen(false)
      resetRuleForm()
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('employees.compliance.errors.save_failed', "No s'ha pogut desar"),
        description: err instanceof Error ? err.message : undefined,
      })
    }
  }

  return (
    <div className="space-y-8">
      <EmployeesComplianceDashboard />

      {!canManage ? null : isLoading ? (
        <div className="flex items-center justify-center h-48">
          <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-primary" />
        </div>
      ) : error ? (
        <div className="rounded-2xl border border-red-200 bg-red-50 p-6 text-center">
          <p className="text-sm text-red-700 font-medium">
            {t('employees.compliance.errors.load_failed', "No s'ha pogut carregar el catàleg")}
          </p>
        </div>
      ) : (
        <>
      <div className="rounded-2xl border bg-card p-4 sm:p-6 space-y-4">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div className="flex items-start gap-3 min-w-0">
            <div className="h-9 w-9 rounded-lg bg-primary/10 flex items-center justify-center shrink-0">
              <ShieldCheck className="h-4 w-4 text-primary" aria-hidden />
            </div>
            <div className="min-w-0">
              <h2 className="text-base font-semibold">
                {t('employees.compliance.types_title', 'Tipus de requeriment')}
              </h2>
              <p className="text-sm text-muted-foreground">
                {t(
                  'employees.compliance.types_hint',
                  'Catàleg de plataforma i tipus personalitzats del tenant.',
                )}
              </p>
            </div>
          </div>
          <Button
            className="gap-2"
            onClick={() => {
              resetTypeForm()
              setTypeDialogOpen(true)
            }}
          >
            <Plus className="h-4 w-4" />
            {t('employees.compliance.add_type', 'Nou tipus')}
          </Button>
        </div>

        <div className="overflow-x-auto rounded-xl border">
          <table className="min-w-full text-sm">
            <thead className="bg-muted/50 text-left">
              <tr>
                <th className="px-3 py-2 font-medium">{t('employees.compliance.col_code', 'Codi')}</th>
                <th className="px-3 py-2 font-medium">{t('employees.compliance.col_name', 'Nom')}</th>
                <th className="px-3 py-2 font-medium">{t('employees.compliance.col_category', 'Categoria')}</th>
                <th className="px-3 py-2 font-medium">{t('employees.compliance.col_source', 'Origen')}</th>
                <th className="px-3 py-2 font-medium">{t('employees.compliance.col_validity', 'Vigència (mesos)')}</th>
              </tr>
            </thead>
            <tbody>
              {types.length === 0 ? (
                <tr>
                  <td colSpan={5} className="px-3 py-6 text-center text-muted-foreground">
                    {t('employees.compliance.types_empty', 'Cap tipus de requeriment')}
                  </td>
                </tr>
              ) : (
                types.map((row) => (
                  <tr key={row.id} className="border-t">
                    <td className="px-3 py-2 font-mono text-xs">{row.code}</td>
                    <td className="px-3 py-2">{row.name}</td>
                    <td className="px-3 py-2">
                      {t(`employees.compliance.category.${row.category}`, row.category)}
                    </td>
                    <td className="px-3 py-2">
                      {row.tenant_id
                        ? t('employees.compliance.source_tenant', 'Tenant')
                        : t('employees.compliance.source_platform', 'Plataforma')}
                    </td>
                    <td className="px-3 py-2">{row.default_validity_months ?? '—'}</td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </div>

      <div className="rounded-2xl border bg-card p-4 sm:p-6 space-y-4">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h2 className="text-base font-semibold">
              {t('employees.compliance.rules_title', 'Regles de compliment')}
            </h2>
            <p className="text-sm text-muted-foreground">
              {t(
                'employees.compliance.rules_hint',
                'MVP: nomes regles ambbit tenant. Altres ambitts es poden crear pero encara no bloquegen.',
              )}
            </p>
          </div>
          <Button
            className="gap-2"
            disabled={types.length === 0}
            onClick={() => {
              resetRuleForm()
              setRuleTypeId(types[0]?.id ?? '')
              setRuleDialogOpen(true)
            }}
          >
            <Plus className="h-4 w-4" />
            {t('employees.compliance.add_rule', 'Nova regla tenant')}
          </Button>
        </div>

        <div className="overflow-x-auto rounded-xl border">
          <table className="min-w-full text-sm">
            <thead className="bg-muted/50 text-left">
              <tr>
                <th className="px-3 py-2 font-medium">{t('employees.compliance.col_requirement', 'Requeriment')}</th>
                <th className="px-3 py-2 font-medium">{t('employees.compliance.col_scope', 'Àmbit')}</th>
                <th className="px-3 py-2 font-medium">{t('employees.compliance.col_blocking', 'Bloquejant')}</th>
                <th className="px-3 py-2 font-medium">{t('employees.compliance.col_grace', 'Gràcia (dies)')}</th>
              </tr>
            </thead>
            <tbody>
              {rules.length === 0 ? (
                <tr>
                  <td colSpan={4} className="px-3 py-6 text-center text-muted-foreground">
                    {t('employees.compliance.rules_empty', 'Cap regla activa')}
                  </td>
                </tr>
              ) : (
                rules.map((row) => {
                  const req = typeMap.get(row.requirement_type_id)
                  return (
                    <tr key={row.id} className="border-t">
                      <td className="px-3 py-2">
                        {req ? `${req.code} — ${req.name}` : row.requirement_type_id}
                      </td>
                      <td className="px-3 py-2">
                        {t(`employees.compliance.scope.${row.scope_type}`, row.scope_type)}
                      </td>
                      <td className="px-3 py-2">
                        {row.is_blocking
                          ? t('employees.compliance.yes', 'Sí')
                          : t('employees.compliance.no', 'No')}
                      </td>
                      <td className="px-3 py-2">{row.grace_period_days}</td>
                    </tr>
                  )
                })
              )}
            </tbody>
          </table>
        </div>
      </div>

      <Dialog open={typeDialogOpen} onOpenChange={setTypeDialogOpen}>
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>{t('employees.compliance.add_type', 'Nou tipus')}</DialogTitle>
          </DialogHeader>
          <div className="space-y-3">
            <div>
              <label className="text-sm font-medium">{t('employees.compliance.col_code', 'Codi')}</label>
              <Input value={typeCode} onChange={(e) => setTypeCode(e.target.value)} placeholder="PRL_ADVANCED" />
            </div>
            <div>
              <label className="text-sm font-medium">{t('employees.compliance.col_name', 'Nom')}</label>
              <Input value={typeName} onChange={(e) => setTypeName(e.target.value)} />
            </div>
            <div>
              <label className="text-sm font-medium">{t('employees.compliance.col_category', 'Categoria')}</label>
              <select
                className="mt-1 w-full rounded-md border bg-background px-3 py-2 text-sm"
                value={typeCategory}
                onChange={(e) => setTypeCategory(e.target.value as ComplianceRequirementType['category'])}
              >
                {TYPE_CATEGORIES.map((cat) => (
                  <option key={cat} value={cat}>
                    {t(`employees.compliance.category.${cat}`, cat)}
                  </option>
                ))}
              </select>
            </div>
            <div>
              <label className="text-sm font-medium">{t('employees.compliance.col_validity', 'Vigència (mesos)')}</label>
              <Input
                type="number"
                min={1}
                value={typeValidityMonths}
                onChange={(e) => setTypeValidityMonths(e.target.value)}
              />
            </div>
            <Button className="w-full" disabled={upsertType.isPending} onClick={() => void handleCreateType()}>
              {upsertType.isPending ? <Loader2 className="h-4 w-4 animate-spin" /> : t('employees.compliance.save', 'Desar')}
            </Button>
          </div>
        </DialogContent>
      </Dialog>

      <Dialog open={ruleDialogOpen} onOpenChange={setRuleDialogOpen}>
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>{t('employees.compliance.add_rule', 'Nova regla tenant')}</DialogTitle>
          </DialogHeader>
          <div className="space-y-3">
            <div>
              <label className="text-sm font-medium">{t('employees.compliance.col_requirement', 'Requeriment')}</label>
              <select
                className="mt-1 w-full rounded-md border bg-background px-3 py-2 text-sm"
                value={ruleTypeId}
                onChange={(e) => setRuleTypeId(e.target.value)}
              >
                {types.map((row) => (
                  <option key={row.id} value={row.id}>
                    {row.code} — {row.name}
                  </option>
                ))}
              </select>
            </div>
            <div className="flex items-center gap-2">
              <input
                id="rule-blocking"
                type="checkbox"
                checked={ruleBlocking}
                onChange={(e) => setRuleBlocking(e.target.checked)}
              />
              <label htmlFor="rule-blocking" className="text-sm">
                {t('employees.compliance.col_blocking', 'Bloquejant')}
              </label>
            </div>
            <div>
              <label className="text-sm font-medium">{t('employees.compliance.col_grace', 'Gràcia (dies)')}</label>
              <Input
                type="number"
                min={0}
                value={ruleGraceDays}
                onChange={(e) => setRuleGraceDays(e.target.value)}
              />
            </div>
            <Button className="w-full" disabled={upsertRule.isPending} onClick={() => void handleCreateRule()}>
              {upsertRule.isPending ? <Loader2 className="h-4 w-4 animate-spin" /> : t('employees.compliance.save', 'Desar')}
            </Button>
          </div>
        </DialogContent>
      </Dialog>
        </>
      )}
    </div>
  )
}
