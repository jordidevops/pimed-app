import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Loader2, Package, Plus, ShieldAlert } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useToast } from '@/hooks/use-toast'
import {
  useAssetTypes,
  useUpsertAssetType,
  type AssetType,
  type AssetTypeCategory,
} from '../api/useAssetTypes'
import {
  useAssetRequirementRules,
  useUpsertAssetRequirementRule,
} from '../api/useAssetRequirementRules'

const CATEGORIES: AssetTypeCategory[] = ['epi', 'vehicle', 'tool', 'device', 'other']

export function EmployeesAssetTypesTab() {
  const { t } = useTranslation('employees')
  const { toast } = useToast()
  const { data: types = [], isLoading, error } = useAssetTypes()
  const { data: rules = [], isLoading: rulesLoading, error: rulesError } =
    useAssetRequirementRules()
  const upsert = useUpsertAssetType()
  const upsertRule = useUpsertAssetRequirementRule()

  const [open, setOpen] = useState(false)
  const [ruleOpen, setRuleOpen] = useState(false)
  const [code, setCode] = useState('')
  const [name, setName] = useState('')
  const [category, setCategory] = useState<AssetTypeCategory>('epi')
  const [requiresReturn, setRequiresReturn] = useState(true)
  const [requiresCalibration, setRequiresCalibration] = useState(false)
  const [calibrationDays, setCalibrationDays] = useState('365')
  const [blocksDispatch, setBlocksDispatch] = useState(false)

  const [ruleTypeId, setRuleTypeId] = useState('')
  const [ruleBlocking, setRuleBlocking] = useState(true)

  const platformTypes = useMemo(() => types.filter((x) => !x.tenant_id), [types])
  const tenantTypes = useMemo(() => types.filter((x) => !!x.tenant_id), [types])

  const typeMap = useMemo(() => {
    const map = new Map<string, AssetType>()
    for (const row of types) map.set(row.id, row)
    return map
  }, [types])

  function resetForm() {
    setCode('')
    setName('')
    setCategory('epi')
    setRequiresReturn(true)
    setRequiresCalibration(false)
    setCalibrationDays('365')
    setBlocksDispatch(false)
  }

  function resetRuleForm() {
    setRuleTypeId(types[0]?.id ?? '')
    setRuleBlocking(true)
  }

  async function onCreate() {
    try {
      await upsert.mutateAsync({
        code,
        name,
        category,
        requires_return: requiresReturn,
        requires_calibration: requiresCalibration,
        calibration_interval_days: requiresCalibration
          ? Number(calibrationDays) || null
          : null,
        blocks_dispatch_if_missing: blocksDispatch,
      })
      toast({ title: t('employees.assets.type_saved', 'Tipus d’actiu desat') })
      setOpen(false)
      resetForm()
    } catch (e) {
      toast({
        variant: 'destructive',
        title: t('employees.assets.type_save_failed', 'No s’ha pogut desar'),
        description: e instanceof Error ? e.message : undefined,
      })
    }
  }

  async function onCreateRule() {
    if (!ruleTypeId) {
      toast({
        variant: 'destructive',
        title: t('employees.assets.errors.required_fields', 'Omple els camps obligatoris'),
      })
      return
    }
    try {
      await upsertRule.mutateAsync({
        asset_type_id: ruleTypeId,
        scope_type: 'tenant',
        is_blocking: ruleBlocking,
      })
      toast({
        title: t('employees.assets.rule_saved', 'Regla de readiness d’actiu creada'),
      })
      setRuleOpen(false)
      resetRuleForm()
    } catch (e) {
      toast({
        variant: 'destructive',
        title: t('employees.assets.rule_save_failed', 'No s’ha pogut desar la regla'),
        description: e instanceof Error ? e.message : undefined,
      })
    }
  }

  function renderRow(row: AssetType) {
    return (
      <li
        key={row.id}
        className="flex flex-wrap items-start justify-between gap-2 rounded-lg border px-3 py-2 text-sm"
      >
        <div>
          <p className="font-medium">
            {row.name}{' '}
            <span className="text-xs font-normal text-muted-foreground">({row.code})</span>
          </p>
          <p className="text-xs text-muted-foreground">
            {row.category}
            {row.requires_calibration
              ? ` · calib. ${row.calibration_interval_days ?? '—'}d`
              : ''}
            {row.blocks_dispatch_if_missing
              ? ` · ${t('employees.assets.blocks_dispatch', 'bloqueja si falta')}`
              : ''}
            {!row.tenant_id
              ? ` · ${t('employees.assets.platform', 'plataforma')}`
              : ''}
          </p>
        </div>
      </li>
    )
  }

  if (isLoading || rulesLoading) {
    return (
      <div className="flex items-center gap-2 text-sm text-muted-foreground py-8">
        <Loader2 className="h-4 w-4 animate-spin" />
        {t('employees.assets.loading', 'Carregant tipus d’actiu…')}
      </div>
    )
  }

  if (error || rulesError) {
    return (
      <p className="text-sm text-destructive">
        {t('employees.assets.load_failed', 'No s’han pogut carregar els tipus d’actiu')}
      </p>
    )
  }

  return (
    <div className="space-y-8 max-w-3xl">
      <div className="space-y-6">
        <div className="flex flex-wrap items-start justify-between gap-2">
          <div>
            <h3 className="text-sm font-semibold flex items-center gap-2">
              <Package className="h-4 w-4" aria-hidden />
              {t('employees.assets.types_title', 'Tipus d’actiu')}
            </h3>
            <p className="text-xs text-muted-foreground">
              {t(
                'employees.assets.types_hint',
                'Catàleg de tipus (EPI, vehicle, eina). Les instàncies físiques continuen a data.assets (EAM).',
              )}
            </p>
          </div>
          <Button type="button" size="sm" onClick={() => setOpen(true)}>
            <Plus className="h-4 w-4 mr-1" />
            {t('employees.assets.add_type', 'Nou tipus')}
          </Button>
        </div>

        {tenantTypes.length > 0 ? (
          <div className="space-y-2">
            <h4 className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
              {t('employees.assets.tenant_types', 'Del tenant')}
            </h4>
            <ul className="space-y-2">{tenantTypes.map(renderRow)}</ul>
          </div>
        ) : null}

        <div className="space-y-2">
          <h4 className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
            {t('employees.assets.platform_types', 'Plataforma')}
          </h4>
          <ul className="space-y-2">{platformTypes.map(renderRow)}</ul>
        </div>
      </div>

      <div className="space-y-4 border-t pt-6">
        <div className="flex flex-wrap items-start justify-between gap-2">
          <div>
            <h3 className="text-sm font-semibold flex items-center gap-2">
              <ShieldAlert className="h-4 w-4" aria-hidden />
              {t('employees.assets.rules_title', 'Regles de readiness')}
            </h3>
            <p className="text-xs text-muted-foreground">
              {t(
                'employees.assets.rules_hint',
                'Exigeix un tipus d’actiu assignat (calibratge vàlid). Motiu: MISSING_ASSET:<codi>.',
              )}
            </p>
          </div>
          <Button
            type="button"
            size="sm"
            variant="outline"
            disabled={types.length === 0}
            onClick={() => {
              resetRuleForm()
              setRuleOpen(true)
            }}
          >
            <Plus className="h-4 w-4 mr-1" />
            {t('employees.assets.add_rule', 'Nova regla')}
          </Button>
        </div>

        {rules.length === 0 ? (
          <p className="text-sm text-muted-foreground">
            {t('employees.assets.rules_empty', 'Cap regla d’actiu activa.')}
          </p>
        ) : (
          <ul className="space-y-2">
            {rules.map((rule) => {
              const at = typeMap.get(rule.asset_type_id)
              return (
                <li
                  key={rule.id}
                  className="rounded-lg border px-3 py-2 text-sm flex flex-wrap justify-between gap-2"
                >
                  <div>
                    <p className="font-medium">
                      {at?.name ?? rule.asset_type_id}{' '}
                      <span className="text-xs font-normal text-muted-foreground">
                        ({at?.code ?? '—'})
                      </span>
                    </p>
                    <p className="text-xs text-muted-foreground">
                      {rule.scope_type}
                      {rule.is_blocking
                        ? ` · ${t('employees.assets.blocking', 'bloquejant')}`
                        : ` · ${t('employees.assets.informational', 'informativa')}`}
                      {!rule.is_active
                        ? ` · ${t('employees.assets.inactive', 'inactiva')}`
                        : ''}
                    </p>
                  </div>
                </li>
              )
            })}
          </ul>
        )}
      </div>

      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{t('employees.assets.add_type', 'Nou tipus')}</DialogTitle>
          </DialogHeader>
          <div className="space-y-3">
            <div>
              <label className="text-xs font-medium">Code</label>
              <Input value={code} onChange={(e) => setCode(e.target.value)} placeholder="EPI_CUSTOM" />
            </div>
            <div>
              <label className="text-xs font-medium">
                {t('employees.assets.name', 'Nom')}
              </label>
              <Input value={name} onChange={(e) => setName(e.target.value)} />
            </div>
            <div>
              <label className="text-xs font-medium">
                {t('employees.assets.category', 'Categoria')}
              </label>
              <select
                className="w-full h-9 rounded-md border bg-background px-2 text-sm"
                value={category}
                onChange={(e) => setCategory(e.target.value as AssetTypeCategory)}
              >
                {CATEGORIES.map((c) => (
                  <option key={c} value={c}>
                    {c}
                  </option>
                ))}
              </select>
            </div>
            <label className="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                checked={requiresReturn}
                onChange={(e) => setRequiresReturn(e.target.checked)}
              />
              {t('employees.assets.requires_return', 'Requereix devolució')}
            </label>
            <label className="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                checked={requiresCalibration}
                onChange={(e) => setRequiresCalibration(e.target.checked)}
              />
              {t('employees.assets.requires_calibration', 'Requereix calibratge')}
            </label>
            {requiresCalibration ? (
              <div>
                <label className="text-xs font-medium">
                  {t('employees.assets.calibration_days', 'Interval calibratge (dies)')}
                </label>
                <Input
                  type="number"
                  min={1}
                  value={calibrationDays}
                  onChange={(e) => setCalibrationDays(e.target.value)}
                />
              </div>
            ) : null}
            <label className="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                checked={blocksDispatch}
                onChange={(e) => setBlocksDispatch(e.target.checked)}
              />
              {t(
                'employees.assets.blocks_if_missing',
                'Hint: tipus candidat a regla MISSING_ASSET',
              )}
            </label>
            <Button
              type="button"
              disabled={!code.trim() || !name.trim() || upsert.isPending}
              onClick={() => void onCreate()}
            >
              {upsert.isPending ? <Loader2 className="h-4 w-4 animate-spin" /> : null}
              {t('employees.assets.save', 'Desar')}
            </Button>
          </div>
        </DialogContent>
      </Dialog>

      <Dialog open={ruleOpen} onOpenChange={setRuleOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{t('employees.assets.add_rule', 'Nova regla')}</DialogTitle>
          </DialogHeader>
          <div className="space-y-3">
            <div>
              <label className="text-xs font-medium">
                {t('employees.assets.rule_type', 'Tipus d’actiu')}
              </label>
              <select
                className="w-full h-9 rounded-md border bg-background px-2 text-sm"
                value={ruleTypeId}
                onChange={(e) => setRuleTypeId(e.target.value)}
              >
                {types.map((at) => (
                  <option key={at.id} value={at.id}>
                    {at.name} ({at.code})
                  </option>
                ))}
              </select>
            </div>
            <p className="text-xs text-muted-foreground">
              {t(
                'employees.assets.rule_scope_hint',
                'Àmbit tenant (dept/lloc/site disponibles via API multi-scope).',
              )}
            </p>
            <label className="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                checked={ruleBlocking}
                onChange={(e) => setRuleBlocking(e.target.checked)}
              />
              {t('employees.assets.rule_blocking', 'Bloquejant (MISSING_ASSET)')}
            </label>
            <Button
              type="button"
              disabled={!ruleTypeId || upsertRule.isPending}
              onClick={() => void onCreateRule()}
            >
              {upsertRule.isPending ? <Loader2 className="h-4 w-4 animate-spin" /> : null}
              {t('employees.assets.save', 'Desar')}
            </Button>
          </div>
        </DialogContent>
      </Dialog>
    </div>
  )
}
