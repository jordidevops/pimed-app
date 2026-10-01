import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { useToast } from '@/hooks/use-toast'
import { getContactSites } from '@/features/contacts/api/contactsService'
import { listTenantPlans } from '@/features/field-service/api/maintenancePlansService'
import { supabase } from '@/lib/supabase'
import {
  linkAgreementCoverage,
  linkAgreementMaintenancePlan,
  listAgreementCoverage,
  listAgreementMaintenancePlans,
  unlinkAgreementCoverage,
  unlinkAgreementMaintenancePlan,
  type AgreementCoverageEntityType,
} from '../api/commercialFlowService'

interface AgreementCoveragePlansSectionProps {
  agreementId: string
  clientId: string
  tenantId: string
  clientName: string
}

export function AgreementCoveragePlansSection({
  agreementId,
  clientId,
  tenantId,
  clientName,
}: AgreementCoveragePlansSectionProps) {
  const { t } = useTranslation('projects')
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const [entityType, setEntityType] = useState<AgreementCoverageEntityType>('contact_site')
  const [entityId, setEntityId] = useState('')
  const [planId, setPlanId] = useState('')

  const coverageQuery = useQuery({
    queryKey: ['commercial_agreement_coverage', agreementId],
    queryFn: () => listAgreementCoverage(agreementId),
  })
  const plansQuery = useQuery({
    queryKey: ['commercial_agreement_maintenance_plans', agreementId],
    queryFn: () => listAgreementMaintenancePlans(agreementId),
  })
  const sitesQuery = useQuery({
    queryKey: ['contact_sites', clientId],
    queryFn: () => getContactSites(clientId),
    enabled: !!clientId,
  })
  const assetsQuery = useQuery({
    queryKey: ['assets', 'by-client-sites', clientId],
    queryFn: async () => {
      const sites = await getContactSites(clientId)
      const siteIds = sites.map((s) => s.id).filter(Boolean) as string[]
      if (siteIds.length === 0) return [] as Array<{ id: string; name: string }>
      const { data, error } = await supabase
        .from('assets')
        .select('id, name')
        .in('contact_site_id', siteIds)
      if (error) throw error
      return (data ?? []) as Array<{ id: string; name: string }>
    },
    enabled: !!clientId && entityType === 'asset',
  })
  const tenantPlansQuery = useQuery({
    queryKey: ['maintenance_plans', 'tenant', tenantId, 'for-agreement'],
    queryFn: () => listTenantPlans(tenantId, { pageSize: 100 }),
    enabled: !!tenantId,
  })

  async function refresh() {
    await Promise.all([
      queryClient.invalidateQueries({ queryKey: ['commercial_agreement_coverage', agreementId] }),
      queryClient.invalidateQueries({
        queryKey: ['commercial_agreement_maintenance_plans', agreementId],
      }),
      queryClient.invalidateQueries({ queryKey: ['commercial_agreements', 'coverage_counts'] }),
    ])
  }

  const linkCoverage = useMutation({
    mutationFn: () =>
      linkAgreementCoverage({
        agreementId,
        entityType,
        entityId: entityType === 'contact' ? clientId : entityId,
      }),
    onSuccess: async () => {
      setEntityId('')
      await refresh()
    },
    onError: (err: unknown) => {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : String(err),
      })
    },
  })

  const unlinkCoverage = useMutation({
    mutationFn: (row: { entityType: AgreementCoverageEntityType; entityId: string }) =>
      unlinkAgreementCoverage({
        agreementId,
        entityType: row.entityType,
        entityId: row.entityId,
      }),
    onSuccess: refresh,
    onError: (err: unknown) => {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : String(err),
      })
    },
  })

  const linkPlan = useMutation({
    mutationFn: () =>
      linkAgreementMaintenancePlan({ agreementId, maintenancePlanId: planId }),
    onSuccess: async () => {
      setPlanId('')
      await refresh()
    },
    onError: (err: unknown) => {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : String(err),
      })
    },
  })

  const unlinkPlan = useMutation({
    mutationFn: (maintenancePlanId: string) =>
      unlinkAgreementMaintenancePlan({ agreementId, maintenancePlanId }),
    onSuccess: refresh,
    onError: (err: unknown) => {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : String(err),
      })
    },
  })

  const coverage = coverageQuery.data ?? []
  const linkedPlans = plansQuery.data ?? []
  const sites = sitesQuery.data ?? []
  const assets = assetsQuery.data ?? []
  const tenantPlans = tenantPlansQuery.data?.rows ?? []
  const linkedPlanIds = new Set(linkedPlans.map((p) => p.maintenancePlanId))
  const availablePlans = tenantPlans.filter((p) => p.id && !linkedPlanIds.has(p.id))

  function entityTypeLabel(type: AgreementCoverageEntityType): string {
    if (type === 'contact') return t('projects.agreements.coverage_type_contact', 'Client')
    if (type === 'contact_site') return t('projects.agreements.coverage_type_site', 'Seu')
    return t('projects.agreements.coverage_type_asset', 'Actiu')
  }

  const canAddCoverage =
    entityType === 'contact'
      ? !coverage.some((c) => c.entityType === 'contact' && c.entityId === clientId)
      : !!entityId

  return (
    <div className="space-y-4 border-t border-border pt-3">
      <div className="space-y-2">
        <h3 className="text-sm font-semibold text-foreground">
          {t('projects.agreements.coverage_title', 'Cobertura')}
        </h3>
        <p className="text-xs text-muted-foreground">
          {t(
            'projects.agreements.coverage_help',
            'Què cobreix aquest acord (client, seu o actiu). No canvia com es generen les ordres del pla.',
          )}
        </p>
        {coverage.length === 0 ? (
          <p className="text-sm text-muted-foreground">
            {t('projects.agreements.coverage_empty', 'Cap cobertura vinculada.')}
          </p>
        ) : (
          <ul className="space-y-1.5 text-sm">
            {coverage.map((row) => (
              <li key={row.id} className="flex flex-wrap items-center justify-between gap-2">
                <span>
                  <span className="text-muted-foreground">{entityTypeLabel(row.entityType)} · </span>
                  {row.label}
                </span>
                <Button
                  type="button"
                  size="sm"
                  variant="outline"
                  disabled={unlinkCoverage.isPending}
                  onClick={() =>
                    unlinkCoverage.mutate({
                      entityType: row.entityType,
                      entityId: row.entityId,
                    })
                  }
                >
                  {t('projects.agreements.coverage_unlink', 'Desvincular')}
                </Button>
              </li>
            ))}
          </ul>
        )}
        <div className="flex flex-wrap items-end gap-2">
          <label className="flex min-w-36 flex-col gap-1 text-sm">
            <span>{t('projects.agreements.coverage_type', 'Tipus')}</span>
            <select
              className="flex h-9 rounded-md border border-input bg-background px-3 text-sm"
              value={entityType}
              onChange={(e) => {
                setEntityType(e.target.value as AgreementCoverageEntityType)
                setEntityId('')
              }}
            >
              <option value="contact">{entityTypeLabel('contact')}</option>
              <option value="contact_site">{entityTypeLabel('contact_site')}</option>
              <option value="asset">{entityTypeLabel('asset')}</option>
            </select>
          </label>
          {entityType === 'contact' ? (
            <p className="pb-2 text-sm text-muted-foreground">{clientName}</p>
          ) : (
            <label className="flex min-w-48 flex-1 flex-col gap-1 text-sm">
              <span>
                {entityType === 'contact_site'
                  ? t('projects.agreements.coverage_pick_site', 'Seu')
                  : t('projects.agreements.coverage_pick_asset', 'Actiu')}
              </span>
              <select
                className="flex h-9 w-full rounded-md border border-input bg-background px-3 text-sm"
                value={entityId}
                onChange={(e) => setEntityId(e.target.value)}
              >
                <option value="">—</option>
                {entityType === 'contact_site'
                  ? sites.map((site) => (
                      <option key={site.id} value={site.id ?? ''}>
                        {site.name}
                      </option>
                    ))
                  : assets.map((asset) => (
                      <option key={asset.id} value={asset.id}>
                        {asset.name}
                      </option>
                    ))}
              </select>
            </label>
          )}
          <Button
            type="button"
            size="sm"
            disabled={!canAddCoverage || linkCoverage.isPending}
            onClick={() => linkCoverage.mutate()}
          >
            {t('projects.agreements.coverage_link', 'Vincular cobertura')}
          </Button>
        </div>
      </div>

      <div className="space-y-2">
        <h3 className="text-sm font-semibold text-foreground">
          {t('projects.agreements.plans_title', 'Plans de manteniment')}
        </h3>
        <p className="text-xs text-muted-foreground">
          {t(
            'projects.agreements.plans_help',
            'El pla genera les ordres; aquí només es declara que van amb aquest acord.',
          )}
        </p>
        {linkedPlans.length === 0 ? (
          <p className="text-sm text-muted-foreground">
            {t('projects.agreements.plans_empty', 'Cap pla vinculat.')}
          </p>
        ) : (
          <ul className="space-y-1.5 text-sm">
            {linkedPlans.map((row) => (
              <li key={row.id} className="flex flex-wrap items-center justify-between gap-2">
                <span>{row.planName}</span>
                <Button
                  type="button"
                  size="sm"
                  variant="outline"
                  disabled={unlinkPlan.isPending}
                  onClick={() => unlinkPlan.mutate(row.maintenancePlanId)}
                >
                  {t('projects.agreements.plans_unlink', 'Desvincular')}
                </Button>
              </li>
            ))}
          </ul>
        )}
        <div className="flex flex-wrap items-end gap-2">
          <label className="flex min-w-48 flex-1 flex-col gap-1 text-sm">
            <span>{t('projects.agreements.plans_pick', 'Pla del tenant')}</span>
            <select
              className="flex h-9 w-full rounded-md border border-input bg-background px-3 text-sm"
              value={planId}
              onChange={(e) => setPlanId(e.target.value)}
            >
              <option value="">
                {availablePlans.length === 0
                  ? t('projects.agreements.plans_no_candidates', 'No hi ha plans disponibles.')
                  : '—'}
              </option>
              {availablePlans.map((plan) => (
                <option key={plan.id} value={plan.id ?? ''}>
                  {plan.name}
                </option>
              ))}
            </select>
          </label>
          <Button
            type="button"
            size="sm"
            disabled={!planId || linkPlan.isPending}
            onClick={() => linkPlan.mutate()}
          >
            {t('projects.agreements.plans_link', 'Vincular pla')}
          </Button>
        </div>
      </div>
    </div>
  )
}
