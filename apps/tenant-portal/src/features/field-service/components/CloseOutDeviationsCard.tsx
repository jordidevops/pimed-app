import { useEffect, useMemo, useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { AlertTriangle, Route } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Input } from '@/components/ui/input'
import { useToast } from '@/hooks/use-toast'
import { supabase } from '@/lib/supabase'
import { useProjectWorkLogSummary } from '@/features/projects/api/useProjectWorkLogSummary'
import {
  formatQuantityChip,
  quantityChipsForUnit,
} from '@/features/catalog/unitOptions'
import { getProjectMaterials } from '@/features/field-service/api/materialsService'
import {
  acceptCommercialDocument,
  issueCommercialDocument,
  listProjectCommercialDocuments,
  projectHasQuoteWaiver,
} from '@/features/commercial/api/commercialFlowService'
import {
  parseDeviationApprovalThresholdEur,
} from '@/features/commercial/utils/deviationApprovalThreshold'
import {
  effectiveProjectCommercialPolicy,
  parseCommercialRegimes,
  resolveProjectCommercialSnapshot,
} from '@/features/commercial/utils/commercialRegimePolicy'
import { useEffectiveSettings } from '@/hooks/useSettings'
import { usePermission } from '@/hooks/usePermission'
import { useTenant } from '@/contexts/TenantContext'
import { CloseOutReviewCard } from './CloseOutReview'
import type { Database } from '@/types/database.types'
import { enqueueProjectLineActual } from '../api/fieldActualsQueue'
import { useProjectFieldOps } from '../hooks/useProjectFieldOps'
import { getFieldProjectSnapshot, patchFieldProjectSnapshot } from '@/lib/today-cache'

type ProjectLine = Database['api']['Views']['project_lines']['Row']

type ProjectCommercialFields = {
  client_id?: string | null
  authorized_total?: number | null
}

interface CloseOutDeviationsCardProps {
  projectId: string
  project: ProjectCommercialFields | null | undefined
  /** When true, completing the visit should be blocked for consumers over authorized total until amendment accepted (or waived B2B). */
  onOverageChange?: (overage: boolean) => void
  onHoursActualChange?: (state: CloseOutHoursActualState) => void
}

export interface CloseOutHoursActualState {
  ready: boolean
  lineId?: string
  quantity?: number
  missingHourLine?: boolean
}

function roundHours(seconds: number): number {
  return Math.round((seconds / 3600) * 100) / 100
}

function formatQty(n: number): string {
  return Number.isInteger(n) ? String(n) : n.toFixed(2).replace(/\.?0+$/, '').replace('.', ',')
}

export function CloseOutDeviationsCard({
  projectId,
  project,
  onOverageChange,
  onHoursActualChange,
}: CloseOutDeviationsCardProps) {
  const { t } = useTranslation('field-service')
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const { totalSeconds } = useProjectWorkLogSummary(projectId)
  const [actualKm, setActualKm] = useState<number | ''>('')
  const [busy, setBusy] = useState(false)
  const canEditPricing = usePermission('commercial.pricing.edit')
  const { activeTenant } = useTenant()
  const localOps = useProjectFieldOps(activeTenant?.id, projectId)
  const { data: effective } = useEffectiveSettings({ tenantId: activeTenant?.id })
  const approvalThreshold = parseDeviationApprovalThresholdEur(effective)

  const { data: lines = [], isLoading: linesLoading } = useQuery({
    queryKey: ['project_lines', projectId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('project_lines')
        .select('*')
        .eq('project_id', projectId)
        .order('position', { ascending: true })
      if (error) {
        if (activeTenant?.id && !navigator.onLine) {
          const snapshot = await getFieldProjectSnapshot(activeTenant.id, projectId)
          if (snapshot?.lines) return snapshot.lines as ProjectLine[]
        }
        throw error
      }
      const result = (data ?? []) as ProjectLine[]
      if (activeTenant?.id) {
        await patchFieldProjectSnapshot(activeTenant.id, projectId, { lines: result })
      }
      return result
    },
    enabled: !!projectId,
  })

  const { data: materials = [] } = useQuery({
    queryKey: ['project_materials', projectId],
    queryFn: () => getProjectMaterials(projectId, activeTenant?.id),
    enabled: !!projectId,
  })

  const { data: docs = [] } = useQuery({
    queryKey: ['commercial_documents', projectId],
    queryFn: () => listProjectCommercialDocuments(projectId),
    enabled: !!projectId,
  })

  const plannedHours = useMemo(
    () =>
      lines
        .filter((l) => (l.unit ?? '').toLowerCase() === 'h')
        .reduce((acc, l) => acc + Number(l.quantity ?? 0), 0),
    [lines],
  )
  const plannedKm = useMemo(
    () =>
      lines
        .filter((l) => (l.unit ?? '').toLowerCase() === 'km')
        .reduce((acc, l) => acc + Number(l.quantity ?? 0), 0),
    [lines],
  )
  const kmLine = useMemo(
    () => lines.find((l) => (l.unit ?? '').toLowerCase() === 'km') ?? null,
    [lines],
  )
  const hourLine = useMemo(
    () => lines.find((l) => (l.unit ?? '').toLowerCase() === 'h') ?? null,
    [lines],
  )

  const actualHours = roundHours(totalSeconds)
  const projectedLines = useMemo(
    () =>
      lines.map((line) => {
        const pending = line.id ? localOps.lineActuals.get(line.id) : undefined
        if (pending) return { ...line, quantity: pending.payload.quantity }
        if (line.id === hourLine?.id) return { ...line, quantity: actualHours }
        return line
      }),
    [lines, localOps.lineActuals, hourLine?.id, actualHours],
  )
  const estimatedTotal = useMemo(
    () =>
      projectedLines.reduce((acc, line) => {
        const net =
          Number(line.quantity ?? 0) *
          Number(line.unit_price ?? 0) *
          (1 - Number(line.discount_pct ?? 0) / 100)
        return acc + net * (1 + Number(line.tax_rate ?? 0) / 100)
      }, 0),
    [projectedLines],
  )
  const authorizedTotal = Number(
    (project as { authorized_total?: number | null } | null | undefined)?.authorized_total ?? 0,
  )
  const snap = resolveProjectCommercialSnapshot(project)

  const tenantRegimes = useMemo(
    () => parseCommercialRegimes(effective),
    [effective],
  )
  const commercialPolicy = useMemo(
    () =>
      effectiveProjectCommercialPolicy({
        commercialRegime: snap.commercialRegime,
        serviceMode: snap.serviceMode,
        tenantRegimes,
      }),
    [snap.commercialRegime, snap.serviceMode, tenantRegimes],
  )

  const { data: hasWaiver = false } = useQuery({
    queryKey: ['quote_waivers', projectId],
    queryFn: () => projectHasQuoteWaiver(projectId),
    enabled: !!projectId,
  })

  const overAuthorized = estimatedTotal > authorizedTotal + 0.009
  const overageAmount = Math.max(0, estimatedTotal - authorizedTotal)
  // Align with SQL: only 'block' prevents close; assessment/off/warn do not.
  const blockOverage =
    overAuthorized &&
    !hasWaiver &&
    commercialPolicy.overage_on_close === 'block'
  const warnOverage =
    overAuthorized &&
    !hasWaiver &&
    !blockOverage &&
    commercialPolicy.overage_on_close === 'warn'
  const canAutoAcceptAmendment =
    canEditPricing && overageAmount <= approvalThreshold + 0.009
  const pendingIssuedAmendment = docs.some(
    (d) => d.doc_type === 'quote_amendment' && d.status === 'issued',
  )

  const acceptedQuote =
    docs.find((d) => d.doc_type === 'quote' && d.status === 'accepted') ??
    docs.find((d) => d.doc_type === 'quote')

  useEffect(() => {
    const pending = kmLine?.id
      ? localOps.lineActuals.get(kmLine.id)?.payload.quantity
      : localOps.lineActuals.get('new:km')?.payload.quantity
    if (pending != null) setActualKm(pending)
    else if (kmLine?.quantity != null) setActualKm(Number(kmLine.quantity))
  }, [kmLine?.id, kmLine?.quantity, localOps.lineActuals])

  useEffect(() => {
    onOverageChange?.(blockOverage)
  }, [blockOverage, onOverageChange])

  useEffect(() => {
    if (linesLoading) {
      onHoursActualChange?.({ ready: false })
    } else if (hourLine?.id) {
      onHoursActualChange?.({
        ready: true,
        lineId: hourLine.id,
        quantity: actualHours,
      })
    } else {
      onHoursActualChange?.({
        ready: true,
        missingHourLine: actualHours > 0,
      })
    }
  }, [
    linesLoading,
    hourLine?.id,
    actualHours,
    onHoursActualChange,
  ])

  const hoursDelta = actualHours - plannedHours
  const kmValue = actualKm === '' ? null : Number(actualKm)
  const kmDelta = kmValue == null ? null : kmValue - plannedKm
  const hasHourDeviation = plannedHours > 0 && Math.abs(hoursDelta) >= 0.05
  const hasKmDeviation = kmDelta != null && Math.abs(kmDelta) >= 0.5
  const hasMaterialExtras = materials.length + localOps.materials.length > 0
  const showCard =
    lines.length > 0 || hasMaterialExtras || totalSeconds > 0 || plannedKm > 0

  if (!showCard) return null

  async function handleApplyHours() {
    if (!hourLine?.id) {
      toast({
        variant: 'destructive',
        description: t(
          'closeout.deviations.no_hour_line',
          "No hi ha cap línia d'hores als imports",
        ),
      })
      return
    }
    setBusy(true)
    try {
      if (!activeTenant?.id) throw new Error('active_tenant_required')
      await enqueueProjectLineActual({
        tenantId: activeTenant.id,
        projectId,
        lineId: hourLine.id,
        unit: 'h',
        quantity: actualHours,
      })
      toast({
        description: t('closeout.offline.saved_locally', 'Desat al dispositiu · pendent de sincronitzar'),
      })
    } catch (err) {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : 'Error',
      })
    } finally {
      setBusy(false)
    }
  }

  async function handleSaveKm() {
    if (kmValue == null || Number.isNaN(kmValue) || kmValue < 0) return
    setBusy(true)
    try {
      if (!activeTenant?.id) throw new Error('active_tenant_required')
      await enqueueProjectLineActual({
        tenantId: activeTenant.id,
        projectId,
        lineId: kmLine?.id ?? undefined,
        unit: 'km',
        quantity: kmValue,
      })
      toast({
        description: t('closeout.offline.saved_locally', 'Desat al dispositiu · pendent de sincronitzar'),
      })
    } catch (err) {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : 'Error',
      })
    } finally {
      setBusy(false)
    }
  }

  async function handleAmendment() {
    setBusy(true)
    try {
      const docId = await issueCommercialDocument({
        projectId,
        docType: 'quote_amendment',
        parentDocumentId: acceptedQuote?.id ?? null,
      })
      if (canAutoAcceptAmendment) {
        await acceptCommercialDocument({
          documentId: docId,
          signature: { method: 'staff_closeout', note: 'amendment_at_closeout' },
        })
        toast({
          title: t('closeout.deviations.amendment_done', 'Ampliació emesa i acceptada'),
        })
      } else {
        toast({
          title: t(
            'closeout.deviations.amendment_proposed',
            'Ampliació proposta · Pendent d’aprovació',
          ),
          description: t(
            'closeout.deviations.office_must_approve',
            'L’oficina ha d’aprovar abans de cobrar.',
          ),
        })
      }
      await queryClient.invalidateQueries({ queryKey: ['commercial_documents', projectId] })
      await queryClient.invalidateQueries({ queryKey: ['projects'] })
      await queryClient.invalidateQueries({ queryKey: ['project', projectId] })
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('closeout.deviations.amendment_failed', "No s'ha pogut crear l'ampliació"),
        description: err instanceof Error ? err.message : undefined,
      })
    } finally {
      setBusy(false)
    }
  }

  const kmChips = quantityChipsForUnit('km')

  return (
    <CloseOutReviewCard
      title={t('closeout.deviations.title', 'Desviacions (imports)')}
      icon={hasHourDeviation || hasKmDeviation || blockOverage ? AlertTriangle : Route}
    >
      <div className="space-y-3 text-sm">
        {localOps.lineActuals.size > 0 && (
          <Badge variant="secondary">
            {t('closeout.offline.pending_sync', 'Pendent de sincronitzar')}
          </Badge>
        )}
        {(plannedHours > 0 || actualHours > 0) && (
          <div className="space-y-1.5">
            <p className="text-muted-foreground">
              {t('closeout.deviations.hours', 'Hores')}
              {': '}
              <span className="font-medium text-foreground tabular-nums">
                {formatQty(plannedHours)} h → {formatQty(actualHours)} h
              </span>
              {hasHourDeviation && (
                <span className="ml-1 text-amber-700 dark:text-amber-300">
                  ({hoursDelta >= 0 ? '+' : ''}
                  {formatQty(hoursDelta)} h)
                </span>
              )}
            </p>
            {hasHourDeviation && hourLine && (
              <Button
                type="button"
                size="sm"
                variant="outline"
                disabled={busy}
                onClick={() => void handleApplyHours()}
              >
                {t('closeout.deviations.apply_hours', 'Aplicar hores reals')}
              </Button>
            )}
          </div>
        )}

        <div className="space-y-1.5">
          <p className="text-muted-foreground">
            {t('closeout.deviations.km', 'Km')}
            {': '}
            <span className="font-medium text-foreground tabular-nums">
              {formatQty(plannedKm)} km
              {kmValue != null ? ` → ${formatQty(kmValue)} km` : ''}
            </span>
            {hasKmDeviation && kmDelta != null && (
              <span className="ml-1 text-amber-700 dark:text-amber-300">
                ({kmDelta >= 0 ? '+' : ''}
                {formatQty(kmDelta)} km)
              </span>
            )}
          </p>
          <div className="flex flex-wrap items-center gap-2">
            <Input
              type="number"
              min="0"
              step="0.5"
              className="h-9 w-28"
              value={actualKm}
              onChange={(e) =>
                setActualKm(e.target.value === '' ? '' : Number(e.target.value))
              }
              aria-label={t('closeout.deviations.km_input', 'Km reals')}
            />
            <Button
              type="button"
              size="sm"
              variant="outline"
              disabled={busy || kmValue == null}
              onClick={() => void handleSaveKm()}
            >
              {t('closeout.deviations.save_km', 'Desar km')}
            </Button>
          </div>
          <div className="flex flex-wrap gap-1">
            {kmChips.map((q) => (
              <button
                key={q}
                type="button"
                onClick={() => setActualKm(q)}
                className={`rounded-md border px-2 py-0.5 text-xs tabular-nums ${
                  actualKm === q
                    ? 'border-primary bg-primary/10 text-primary'
                    : 'border-border text-muted-foreground'
                }`}
              >
                {formatQuantityChip(q)} km
              </button>
            ))}
          </div>
        </div>

        {hasMaterialExtras && (
          <p className="text-muted-foreground">
            {t('closeout.deviations.materials', 'Materials registrats: {{count}}', {
              count: materials.length + localOps.materials.length,
            })}
          </p>
        )}

        {(authorizedTotal > 0 || estimatedTotal > 0) && (
          <div
            className={`rounded-lg border px-3 py-2 ${
              blockOverage
                ? 'border-amber-500/50 bg-amber-50 text-amber-950 dark:bg-amber-950/30 dark:text-amber-100'
                : 'border-border bg-muted/30 text-muted-foreground'
            }`}
          >
            <p className="tabular-nums">
              {t('closeout.deviations.totals', 'Imports {{est}} € · Autoritzat {{auth}} €', {
                est: estimatedTotal.toFixed(2),
                auth: authorizedTotal.toFixed(2),
              })}
            </p>
            {blockOverage && (
              <div className="mt-2 space-y-2">
                <p className="text-sm font-medium">
                  {t(
                    'closeout.deviations.over_authorized',
                    'El total supera l’import autoritzat. Cal una ampliació abans de cobrar-ho.',
                  )}
                </p>
                {pendingIssuedAmendment ? (
                  <p className="text-sm text-amber-800 dark:text-amber-200">
                    {t(
                      'closeout.deviations.pending_approval',
                      'Ampliació pendent d’aprovació de l’oficina.',
                    )}
                  </p>
                ) : (
                  <>
                    {!canAutoAcceptAmendment && (
                      <p className="text-xs">
                        {t(
                          'closeout.deviations.office_must_approve',
                          'L’oficina ha d’aprovar abans de cobrar.',
                        )}
                      </p>
                    )}
                    <Button
                      type="button"
                      size="sm"
                      disabled={busy || !navigator.onLine}
                      onClick={() => void handleAmendment()}
                    >
                      {canAutoAcceptAmendment
                        ? t(
                            'closeout.deviations.create_amendment',
                            'Crear i acceptar ampliació',
                          )
                        : t(
                            'closeout.deviations.propose_amendment',
                            'Proposar ampliació',
                          )}
                    </Button>
                  </>
                )}
              </div>
            )}
            {warnOverage && (
              <p className="mt-1 text-xs">
                {t(
                  'closeout.deviations.overage_warn',
                  'Se supera l’autoritzat: es pot tancar la visita, però cal revisar el sobrecost.',
                )}
              </p>
            )}
          </div>
        )}
      </div>
    </CloseOutReviewCard>
  )
}
