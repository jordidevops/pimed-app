import { useTranslation } from 'react-i18next'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { ShieldAlert } from 'lucide-react'
import { useTenant } from '../../contexts/TenantContext'
import { useToast } from '../../hooks/use-toast'
import { useTenantFeatures } from '../../features/entity-timeline/api/useTenantFeatures'
import { TimelineFeatureDisabledNotice } from '../../features/entity-timeline/components/TimelineFeatureDisabledNotice'
import {
  listEntityRiskRules,
  upsertEntityRiskRule,
  type EntityRiskRule,
  type RiskRuleType,
} from '../../features/entity-timeline/api/riskService'

const RULE_LABELS: Record<RiskRuleType, string> = {
  task_overdue: 'Tasca vençuda sense resoldre',
  unread_mention: 'Menció no llegida',
  pending_signature: 'Signatura pendent',
  employee_status_churn: 'Alta rotació d\'estat (empleat)',
  stale_thread: 'Comentari sense resposta',
}

export function RiskDetectorPage() {
  const { t } = useTranslation('settings')
  const { toast } = useToast()
  const { activeRole, activeTenant } = useTenant()
  const { data: features, isLoading: featuresLoading } = useTenantFeatures()
  const queryClient = useQueryClient()
  const canManage = activeRole === 'owner' || activeRole === 'manager'

  const { data: rules = [], isLoading, isError } = useQuery({
    queryKey: ['entity-risk-rules'],
    queryFn: listEntityRiskRules,
    enabled: canManage,
  })

  const saveMutation = useMutation({
    mutationFn: upsertEntityRiskRule,
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ['entity-risk-rules'] })
      toast({ description: t('risk.saved', 'Regla desada') })
    },
    onError: () => {
      toast({
        variant: 'destructive',
        description: t('risk.save_error', 'No s\'ha pogut desar la regla'),
      })
    },
  })

  if (!featuresLoading && features?.entity_timeline_risk_detector === false) {
    return (
      <TimelineFeatureDisabledNotice
        titleKey="risk.feature_disabled_title"
        titleDefault="Detector de risc no disponible"
        descriptionKey="risk.feature_disabled_description"
        descriptionDefault="Aquesta funcionalitat no està inclosa al pla de la teva organització. Contacta amb suport per ampliar el pla."
      />
    )
  }

  if (!canManage) {
    return (
      <p className="text-sm text-muted-foreground">
        {t('risk.forbidden', 'Només owner/manager pot gestionar el detector de risc.')}
      </p>
    )
  }

  return (
    <div className="space-y-6 max-w-3xl">
      <div className="flex items-start gap-3">
        <ShieldAlert className="h-6 w-6 text-amber-600 shrink-0 mt-0.5" aria-hidden />
        <div>
          <h3 className="text-base font-semibold text-foreground">
            {t('risk.title', 'Detector de risc')}
          </h3>
          <p className="text-sm text-muted-foreground mt-1">
            {t('risk.description', 'Regles proactives que detecten patrons de risc a la timeline i envien alertes.')}
          </p>
        </div>
      </div>

      {isLoading ? (
        <p className="text-sm text-muted-foreground">{t('risk.loading', 'Carregant...')}</p>
      ) : isError ? (
        <p className="text-sm text-destructive">
          {t('risk.load_error', 'No s\'han pogut carregar les regles de risc.')}
        </p>
      ) : rules.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          {t('risk.empty', 'Cap regla configurada. Executa les migracions o contacta amb suport.')}
        </p>
      ) : (
        <ul className="space-y-3">
          {rules.map((rule) => (
            <RiskRuleRow
              key={rule.id}
              rule={rule}
              disabled={saveMutation.isPending}
              onSave={(patch) => saveMutation.mutate({ id: rule.id, ...patch })}
            />
          ))}
        </ul>
      )}
    </div>
  )
}

function RiskRuleRow({
  rule,
  disabled,
  onSave,
}: {
  rule: EntityRiskRule
  disabled: boolean
  onSave: (patch: { threshold_value?: number; is_active?: boolean }) => void
}) {
  const { t } = useTranslation('settings')

  return (
    <li className="rounded-xl border border-border bg-card p-4 flex flex-col sm:flex-row sm:items-center gap-4">
      <div className="flex-1 min-w-0">
        <p className="font-medium text-foreground">
          {t(`risk.rules.${rule.rule_type}`, RULE_LABELS[rule.rule_type])}
        </p>
        <p className="text-xs text-muted-foreground mt-0.5">
          {t('risk.cadence', 'Cadència')}: {rule.scan_cadence}
          {' · '}
          {t('risk.unit', 'Llindar')}: {rule.threshold_value} {rule.threshold_unit}
        </p>
      </div>

      <div className="flex items-center gap-3 shrink-0">
        <label className="flex items-center gap-2 text-sm">
          <input
            type="number"
            min={1}
            className="w-20 rounded-md border border-input bg-background px-2 py-1 text-sm"
            defaultValue={rule.threshold_value}
            disabled={disabled}
            onBlur={(e) => {
              const val = Number(e.target.value)
              if (val > 0 && val !== rule.threshold_value) {
                onSave({ threshold_value: val })
              }
            }}
          />
          <span className="text-muted-foreground">{rule.threshold_unit}</span>
        </label>

        <label className="flex items-center gap-2 text-sm cursor-pointer">
          <input
            type="checkbox"
            checked={rule.is_active}
            disabled={disabled}
            onChange={(e) => onSave({ is_active: e.target.checked })}
          />
          {t('risk.active', 'Activa')}
        </label>
      </div>
    </li>
  )
}
