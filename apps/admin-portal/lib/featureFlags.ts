/**
 * Catàleg de títols humans per feature flags (clau tècnica → etiqueta UI).
 * Si falta una clau, es fa fallback a la clau o a la description de BD.
 */

export type FeatureFlagMeta = {
  title: string
  /** Descripció curta opcional (si la BD no en té) */
  hint?: string
}

export const FEATURE_FLAG_META: Record<string, FeatureFlagMeta> = {
  recruitment_enabled: {
    title: 'Selecció de personal',
    hint: 'Mòdul ATS: ofertes, candidatures, pipeline i hire.',
  },
  tenant_signing_enabled: {
    title: 'Signatures digitals',
    hint: 'Fluxos de generate / sign / monitoring.',
  },
  employee_readiness_gate_enabled: {
    title: 'Gate de readiness d’empleats',
    hint:
      'Kill switch de backend que bloqueja el fitxatge / work log si l’empleat no passa l’elegibilitat (lifecycle + readiness). Sense UI a la web del tenant.',
  },
  station_offline_deferred_punch: {
    title: 'Fitxatge offline (estació)',
    hint: 'Outbox de punches diferits quan l’estació no té xarxa.',
  },
  work_plan_resolver_v2: {
    title: 'Resolució de pla de treball v2',
    hint: 'Resolver canònic resolve_employee_work_plan.',
  },
  entity_timeline_risk_detector: {
    title: 'Timeline — detector de risc',
    hint: 'Detector de risc proactiu (cron, incidents, banner UI).',
  },
  entity_timeline_playbooks: {
    title: 'Timeline — playbooks',
    hint: "Playbooks d'auditoria → tasques automàtiques a la timeline.",
  },
  entity_timeline_webhooks: {
    title: 'Timeline — webhooks',
    hint: 'Webhooks externs per esdeveniments de timeline.',
  },
  entity_timeline_export: {
    title: 'Timeline — export CSV',
    hint: 'Export CSV auditable de la timeline.',
  },
  entity_timeline_manager_feed: {
    title: 'Timeline — activitat al dashboard',
    hint: 'Widget «Activitat avui» al dashboard (owner/manager).',
  },
}

export function getFeatureFlagTitle(key: string): string {
  return FEATURE_FLAG_META[key]?.title ?? key
}

export function getFeatureFlagHint(key: string, dbDescription?: string | null): string | null {
  return FEATURE_FLAG_META[key]?.hint ?? dbDescription ?? null
}

/** Estat efectiu simplificat (override > global 100%). Rollout parcial sense override → false. */
export function isTenantFeatureEffectivelyOn(
  flag: { is_enabled: boolean; rollout_percentage: number },
  override: boolean | undefined,
): boolean {
  if (override !== undefined) return override
  return flag.is_enabled && flag.rollout_percentage >= 100
}
