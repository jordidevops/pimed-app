import { useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Receipt } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { useToast } from '@/hooks/use-toast'
import { usePermission } from '@/hooks/usePermission'
import {
  closeCommercialFiscalYear,
  listCommercialDocumentSeries,
  listCommercialFiscalYears,
  previewNextDocumentNumber,
  reopenCommercialFiscalYear,
} from '@/features/commercial/api/commercialFlowService'
import { commercialErrorMessage } from '@/features/commercial/utils/commercialErrorMessage'

export function CommercialSettingsPage() {
  const { t } = useTranslation('settings')
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const canManage = usePermission('invoices.manage')
  const canView = usePermission('invoices.view') || canManage
  const [previewSeriesId, setPreviewSeriesId] = useState<string | null>(null)
  const [previewOn, setPreviewOn] = useState(() => new Date().toISOString().slice(0, 10))
  const [previewValue, setPreviewValue] = useState<string | null>(null)
  const [yearInput, setYearInput] = useState(() => String(new Date().getFullYear()))
  const [busy, setBusy] = useState(false)

  const seriesQuery = useQuery({
    queryKey: ['commercial_document_series'],
    queryFn: listCommercialDocumentSeries,
    enabled: canView,
  })

  const yearsQuery = useQuery({
    queryKey: ['commercial_fiscal_years'],
    queryFn: listCommercialFiscalYears,
    enabled: canView,
  })

  async function runPreview(seriesId: string) {
    setBusy(true)
    setPreviewSeriesId(seriesId)
    try {
      const next = await previewNextDocumentNumber({
        seriesId,
        issuedOn: previewOn || null,
      })
      setPreviewValue(next)
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('commercial.preview_failed', 'No s’ha pogut previsualitzar'),
        description: commercialErrorMessage(err),
      })
    } finally {
      setBusy(false)
    }
  }

  async function closeYear() {
    if (!canManage) return
    const year = Number(yearInput)
    if (!Number.isFinite(year)) return
    setBusy(true)
    try {
      await closeCommercialFiscalYear(year)
      toast({ title: t('commercial.year_closed', 'Exercici tancat') })
      void yearsQuery.refetch()
      void queryClient.invalidateQueries({ queryKey: ['commercial_fiscal_years'] })
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('commercial.year_action_failed', 'Error d’exercici'),
        description: commercialErrorMessage(err),
      })
    } finally {
      setBusy(false)
    }
  }

  async function reopenYear(year: number) {
    if (!canManage) return
    setBusy(true)
    try {
      await reopenCommercialFiscalYear(year)
      toast({ title: t('commercial.year_reopened', 'Exercici reobert') })
      void yearsQuery.refetch()
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('commercial.year_action_failed', 'Error d’exercici'),
        description: commercialErrorMessage(err),
      })
    } finally {
      setBusy(false)
    }
  }

  if (!canView) {
    return (
      <div className="rounded-xl border border-dashed border-border px-4 py-8 text-center">
        <p className="text-sm text-muted-foreground">
          {t('commercial.forbidden', 'Cal permís de factures per veure sèries i exercicis.')}
        </p>
      </div>
    )
  }

  return (
    <div className="mx-auto max-w-3xl space-y-8">
      <div className="flex items-start gap-3">
        <div className="rounded-lg border border-border bg-muted/40 p-2">
          <Receipt className="h-5 w-5" />
        </div>
        <div>
          <h1 className="text-xl font-semibold">
            {t('tabs.commercial', 'Comercial')}
          </h1>
          <p className="text-sm text-muted-foreground">
            {t(
              'commercial.subtitle',
              'Sèries de numeració (només lectura) i tancament d’exercici natural.',
            )}
          </p>
        </div>
      </div>

      <section className="space-y-3">
        <h2 className="text-sm font-semibold">{t('commercial.series_title', 'Sèries')}</h2>
        <div className="flex flex-wrap items-end gap-2">
          <label className="space-y-1 text-xs text-muted-foreground">
            <span>{t('commercial.preview_date', 'Data orientativa')}</span>
            <Input
              type="date"
              value={previewOn}
              onChange={(e) => setPreviewOn(e.target.value)}
              className="w-44"
            />
          </label>
          {previewValue ? (
            <p className="text-sm">
              {t('commercial.next_number', 'Següent número (orientatiu)')}:{' '}
              <span className="font-semibold tabular-nums">{previewValue}</span>
            </p>
          ) : null}
        </div>
        <ul className="divide-y rounded-xl border border-border bg-card">
          {(seriesQuery.data ?? []).length === 0 ? (
            <li className="px-4 py-3 text-sm text-muted-foreground">—</li>
          ) : (
            (seriesQuery.data ?? []).map((series) => (
              <li
                key={series.id}
                className="flex flex-wrap items-center justify-between gap-2 px-4 py-3 text-sm"
              >
                <div className="space-y-0.5">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="font-medium">{series.name}</span>
                    <Badge variant="outline">{series.doc_type}</Badge>
                    {!series.active ? (
                      <Badge variant="secondary">{t('commercial.inactive', 'Inactiva')}</Badge>
                    ) : null}
                  </div>
                  <p className="text-xs text-muted-foreground">
                    {series.code} · {series.pattern} · {series.reset_policy}
                  </p>
                </div>
                <Button
                  type="button"
                  size="sm"
                  variant={previewSeriesId === series.id ? 'default' : 'outline'}
                  disabled={busy}
                  onClick={() => void runPreview(series.id)}
                >
                  {t('commercial.preview', 'Vista prèvia')}
                </Button>
              </li>
            ))
          )}
        </ul>
        <p className="text-xs text-muted-foreground">
          {t(
            'commercial.series_readonly_help',
            'La sèrie es configura al servidor; la UI no escriu el comptador.',
          )}
        </p>
      </section>

      <section className="space-y-3">
        <h2 className="text-sm font-semibold">
          {t('commercial.fiscal_years_title', 'Exercicis fiscals')}
        </h2>
        <p className="text-xs text-muted-foreground">
          {t(
            'commercial.fiscal_years_help',
            'Any natural (1 gen – 31 des). Independent del calendari laboral d’assistència.',
          )}
        </p>
        {canManage ? (
          <div className="flex flex-wrap items-end gap-2">
            <label className="space-y-1 text-xs text-muted-foreground">
              <span>{t('commercial.year', 'Any')}</span>
              <Input
                inputMode="numeric"
                value={yearInput}
                onChange={(e) => setYearInput(e.target.value)}
                className="w-28"
              />
            </label>
            <Button type="button" size="sm" disabled={busy} onClick={() => void closeYear()}>
              {t('commercial.close_year', 'Tancar exercici')}
            </Button>
          </div>
        ) : null}
        <ul className="divide-y rounded-xl border border-border bg-card">
          {(yearsQuery.data ?? []).length === 0 ? (
            <li className="px-4 py-3 text-sm text-muted-foreground">
              {t('commercial.no_closed_years', 'Cap exercici tancat encara.')}
            </li>
          ) : (
            (yearsQuery.data ?? []).map((fy) => {
              const closed = Boolean(fy.closed_at) && !fy.reopened_at
              return (
                <li
                  key={fy.year}
                  className="flex flex-wrap items-center justify-between gap-2 px-4 py-3 text-sm"
                >
                  <div>
                    <span className="font-medium">{fy.year}</span>
                    <span className="ml-2 text-muted-foreground">
                      {closed
                        ? t('commercial.closed', 'Tancat')
                        : t('commercial.open', 'Obert')}
                    </span>
                  </div>
                  {canManage && closed ? (
                    <Button
                      type="button"
                      size="sm"
                      variant="outline"
                      disabled={busy}
                      onClick={() => void reopenYear(fy.year)}
                    >
                      {t('commercial.reopen_year', 'Reobrir')}
                    </Button>
                  ) : null}
                </li>
              )
            })
          )}
        </ul>
      </section>
    </div>
  )
}
