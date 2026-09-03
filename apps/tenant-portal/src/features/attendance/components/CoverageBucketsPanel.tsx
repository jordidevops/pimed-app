import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { useWorkRoles } from '../api/useWorkRoles'
import {
  useCoverageBuckets,
  layerGap,
  layerValue,
  type CoverageBucket,
  type CoverageBucketLayer,
} from '../api/useCoverageBuckets'

function todayISO(): string {
  const d = new Date()
  const y = d.getFullYear()
  const m = String(d.getMonth() + 1).padStart(2, '0')
  const day = String(d.getDate()).padStart(2, '0')
  return `${y}-${m}-${day}`
}

function bucketColor(b: CoverageBucket, layer: CoverageBucketLayer): string {
  const value = layerValue(b, layer)
  const gap = layerGap(b, layer)
  if (b.required === 0 && value === 0) return 'bg-muted/40'
  if (gap < 0) return 'bg-red-500/80'
  if (gap === 0 && b.required > 0) return 'bg-emerald-500/80'
  if (gap > 0) return 'bg-sky-500/60'
  return 'bg-muted/40'
}

const LAYERS: CoverageBucketLayer[] = ['planned', 'confirmed', 'present', 'qualified']

export function CoverageBucketsPanel({
  date: controlledDate,
  onDateChange,
}: {
  date?: string
  onDateChange?: (iso: string) => void
} = {}) {
  const { t } = useTranslation('attendance')
  const [internalDate, setInternalDate] = useState(todayISO)
  const date = controlledDate ?? internalDate
  const setDate = (next: string) => {
    if (onDateChange) onDateChange(next)
    else setInternalDate(next)
  }
  const [bucketMinutes, setBucketMinutes] = useState<15 | 30>(30)
  const [roleId, setRoleId] = useState('')
  const [layer, setLayer] = useState<CoverageBucketLayer>('planned')
  const { data: roles = [] } = useWorkRoles()
  const { data: buckets = [], isLoading, isError, error, refetch } = useCoverageBuckets({
    date,
    bucketMinutes,
    roleId: roleId || null,
  })

  const summary = useMemo(() => {
    let under = 0
    let ok = 0
    let over = 0
    for (const b of buckets) {
      const value = layerValue(b, layer)
      if (b.required === 0 && value === 0) continue
      const gap = layerGap(b, layer)
      if (gap < 0) under += 1
      else if (gap === 0) ok += 1
      else over += 1
    }
    return { under, ok, over }
  }, [buckets, layer])

  const displayBuckets = useMemo(() => {
    const hasAny = buckets.some((b) => {
      if (b.required > 0) return true
      return LAYERS.some((l) => layerValue(b, l) > 0)
    })
    if (!hasAny) return buckets.filter((b) => b.bucket_start_min >= 6 * 60 && b.bucket_start_min < 22 * 60)
    let first = -1
    let last = -1
    for (let i = 0; i < buckets.length; i++) {
      const b = buckets[i]
      const active = b.required > 0 || LAYERS.some((l) => layerValue(b, l) > 0)
      if (active) {
        if (first < 0) first = i
        last = i
      }
    }
    if (first < 0) return buckets
    const pad = bucketMinutes === 15 ? 4 : 2
    const from = Math.max(0, first - pad)
    const to = Math.min(buckets.length - 1, last + pad)
    return buckets.slice(from, to + 1)
  }, [buckets, bucketMinutes])

  const layerLabel = (l: CoverageBucketLayer) => {
    switch (l) {
      case 'confirmed':
        return t('planificacio.buckets_layer_confirmed', 'Confirmat')
      case 'present':
        return t('planificacio.buckets_layer_present', 'Real')
      case 'qualified':
        return t('planificacio.buckets_layer_qualified', 'Qualificat')
      case 'planned':
      default:
        return t('planificacio.buckets_layer_planned', 'Planificat')
    }
  }

  return (
    <div className="space-y-3 rounded-lg border p-3">
      <div className="flex flex-wrap items-end justify-between gap-2">
        <div>
          <h4 className="text-sm font-semibold">
            {t('planificacio.buckets_title', 'Cobertura per franja')}
          </h4>
          <p className="text-xs text-muted-foreground">
            {t(
              'planificacio.buckets_help_layers',
              'Compara demanda amb planificat, confirmat, present i qualificat. Vermell = gap, verd = cobert, blau = sobrant.',
            )}
          </p>
        </div>
        <div className="flex flex-wrap gap-2">
          <input
            type="date"
            value={date}
            onChange={(e) => setDate(e.target.value)}
            className="rounded border bg-background px-2 py-1 text-xs"
          />
          <select
            value={bucketMinutes}
            onChange={(e) => setBucketMinutes(Number(e.target.value) as 15 | 30)}
            className="rounded border bg-background px-2 py-1 text-xs"
          >
            <option value={30}>{t('planificacio.buckets_30', '30 min')}</option>
            <option value={15}>{t('planificacio.buckets_15', '15 min')}</option>
          </select>
          <select
            value={roleId}
            onChange={(e) => setRoleId(e.target.value)}
            className="rounded border bg-background px-2 py-1 text-xs"
          >
            <option value="">{t('planificacio.buckets_role_all', 'Tots els rols')}</option>
            {roles.map((r) => (
              <option key={r.id} value={r.id}>{r.name}</option>
            ))}
          </select>
          <select
            value={layer}
            onChange={(e) => setLayer(e.target.value as CoverageBucketLayer)}
            className="rounded border bg-background px-2 py-1 text-xs"
          >
            {LAYERS.map((l) => (
              <option key={l} value={l}>{layerLabel(l)}</option>
            ))}
          </select>
        </div>
      </div>

      <div className="flex flex-wrap gap-3 text-xs text-muted-foreground">
        <span>{t('planificacio.buckets_under', 'Gaps')}: {summary.under}</span>
        <span>{t('planificacio.buckets_ok', 'Coberts')}: {summary.ok}</span>
        <span>{t('planificacio.buckets_over', 'Sobrants')}: {summary.over}</span>
        <span className="text-foreground/80">
          {t('planificacio.buckets_layer_active', 'Capa')}: {layerLabel(layer)}
        </span>
      </div>

      {isLoading ? (
        <p className="text-sm text-muted-foreground">{t('common.loading', 'Carregant…')}</p>
      ) : isError ? (
        <div className="text-sm text-destructive">
          <p>{t('planificacio.buckets_load_error', 'No s\'ha pogut carregar la cobertura')}</p>
          <p className="mt-1 text-xs text-muted-foreground">
            {error instanceof Error ? error.message : String(error)}
          </p>
          <Button type="button" size="sm" variant="outline" className="mt-2" onClick={() => void refetch()}>
            {t('common.retry', 'Tornar a provar')}
          </Button>
        </div>
      ) : (
        <div className="overflow-x-auto">
          <div className="flex min-w-max gap-0.5">
            {displayBuckets.map((b) => {
              const value = layerValue(b, layer)
              const gap = layerGap(b, layer)
              return (
                <div
                  key={`${b.bucket_start}-${b.bucket_end}`}
                  className={`flex h-16 w-8 flex-col items-center justify-end rounded-sm ${bucketColor(b, layer)}`}
                  title={
                    `${b.bucket_start}–${b.bucket_end}: `
                    + `P ${b.planned ?? b.assigned ?? 0} · `
                    + `C ${b.confirmed ?? 0} · `
                    + `R ${b.present ?? 0} · `
                    + `Q ${b.qualified ?? 0} / ${b.required} `
                    + `(${layerLabel(layer)} gap ${gap})`
                  }
                >
                  <span className="mb-0.5 text-[9px] font-medium text-white drop-shadow">
                    {b.required > 0 || value > 0 ? `${value}/${b.required}` : ''}
                  </span>
                  <span className="pb-0.5 text-[8px] text-foreground/70">
                    {b.bucket_start.slice(0, 5)}
                  </span>
                </div>
              )
            })}
          </div>
        </div>
      )}
    </div>
  )
}
