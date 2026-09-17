import { useEffect, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { supabase } from '@/lib/supabase'
import { useToast } from '@/hooks/use-toast'
import {
  copyProjectLines,
  searchJobsForPricing,
  type PricingJobSearchRow,
} from '../api/commercialFlowService'
import { rpcErrorMessage } from '../utils/rpcError'

const moneyFmt = new Intl.NumberFormat('ca-ES', {
  style: 'currency',
  currency: 'EUR',
})

interface CopyFromJobDialogProps {
  projectId: string
  currentLineCount: number
  open: boolean
  onClose: () => void
  onCopied: () => void
}

export function CopyFromJobDialog({
  projectId,
  currentLineCount,
  open,
  onClose,
  onCopied,
}: CopyFromJobDialogProps) {
  const { t } = useTranslation('projects')
  const { toast } = useToast()
  const [query, setQuery] = useState('')
  const [debouncedQuery, setDebouncedQuery] = useState('')
  const [completedOnly, setCompletedOnly] = useState(false)
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [mode, setMode] = useState<'append' | 'replace'>(
    currentLineCount === 0 ? 'replace' : 'append',
  )
  const [submitting, setSubmitting] = useState(false)

  useEffect(() => {
    const handle = window.setTimeout(() => setDebouncedQuery(query.trim()), 250)
    return () => window.clearTimeout(handle)
  }, [query])

  useEffect(() => {
    if (!open) return
    setSelectedId(null)
    setMode(currentLineCount === 0 ? 'replace' : 'append')
  }, [open, currentLineCount])

  const { data: project } = useQuery({
    queryKey: ['project_client', projectId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('projects')
        .select('id, client_id, name')
        .eq('id', projectId)
        .single()
      if (error) throw error
      return data
    },
    enabled: open && !!projectId,
  })

  const { data: jobs = [], isFetching } = useQuery({
    queryKey: [
      'search_jobs_for_pricing',
      projectId,
      debouncedQuery,
      completedOnly,
      project?.client_id,
    ],
    queryFn: () =>
      searchJobsForPricing({
        query: debouncedQuery || undefined,
        clientId: project?.client_id,
        excludeProjectId: projectId,
        completedOnly,
      }),
    enabled: open && !!projectId,
  })

  if (!open) return null

  async function handleCopy() {
    if (!selectedId) return
    setSubmitting(true)
    try {
      const result = await copyProjectLines({
        sourceProjectId: selectedId,
        targetProjectId: projectId,
        mode,
      })
      const skipped = result.skipped?.length ?? 0
      toast({
        title:
          skipped > 0
            ? t('projects.lines.copy_partial', "S'han omès algunes línies")
            : t('projects.lines.copy_success', 'Línies copiades'),
        description:
          skipped > 0
            ? result.skipped
                ?.map((row) => row.name || row.reason)
                .filter(Boolean)
                .join(', ')
            : undefined,
      })
      onCopied()
      onClose()
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('projects.lines.copy_failed', "No s'ha pogut copiar el full"),
        description: rpcErrorMessage(err) || undefined,
      })
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <div className="fixed inset-0 z-50 flex items-end sm:items-center justify-center bg-black/40 p-0 sm:p-4">
      <div className="w-full max-w-lg rounded-t-2xl sm:rounded-xl border border-border bg-background p-4 sm:p-6 shadow-lg max-h-[90vh] overflow-y-auto">
        <h3 className="text-lg font-semibold text-foreground mb-1">
          {t('projects.lines.copy_from_job_title', "Copiar el full d'una feina")}
        </h3>
        <p className="text-sm text-muted-foreground mb-4">
          {t(
            'projects.lines.copy_from_job_help',
            "Cerca una OS amb línies i copia-les aquí. Sense permís de preu, es fa servir el PVP del catàleg i s'ometen les línies lliures.",
          )}
        </p>

        <Input
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder={t(
            'projects.lines.copy_search_placeholder',
            'Cerca per nom, client o línia…',
          )}
          className="mb-3"
        />

        <label className="mb-3 flex items-center gap-2 text-sm text-foreground">
          <input
            type="checkbox"
            checked={completedOnly}
            onChange={(e) => setCompletedOnly(e.target.checked)}
          />
          {t('projects.lines.copy_completed_only', 'Només tancades')}
        </label>

        <div className="mb-4 max-h-56 space-y-2 overflow-y-auto">
          {isFetching ? (
            <div className="flex justify-center py-6">
              <div className="h-6 w-6 animate-spin rounded-full border-b-2 border-primary" />
            </div>
          ) : jobs.length === 0 ? (
            <p className="text-sm text-muted-foreground">
              {t('projects.lines.copy_empty', "No s'ha trobat cap feina amb línies.")}
            </p>
          ) : (
            jobs.map((job: PricingJobSearchRow) => (
              <button
                key={job.id}
                type="button"
                onClick={() => setSelectedId(job.id)}
                className={`w-full rounded-lg border px-3 py-2 text-left ${
                  selectedId === job.id
                    ? 'border-primary bg-primary/10'
                    : 'border-border hover:bg-muted/40'
                }`}
              >
                <div className="flex items-start justify-between gap-2">
                  <span className="text-sm font-medium text-foreground">{job.name}</span>
                  <span className="text-xs tabular-nums text-muted-foreground">
                    {moneyFmt.format(Number(job.subtotal ?? 0))}
                  </span>
                </div>
                <p className="mt-0.5 text-xs text-muted-foreground">
                  {job.client_display_name || '—'} ·{' '}
                  {t('projects.lines.copy_lines', '{{count}} línies', {
                    count: job.line_count,
                  })}
                  {job.same_client
                    ? ` · ${t('projects.lines.copy_same_client', 'Mateix client')}`
                    : ''}
                </p>
              </button>
            ))
          )}
        </div>

        {currentLineCount > 0 ? (
          <div className="mb-4 space-y-2">
            <p className="text-xs text-muted-foreground">
              {t(
                'projects.lines.copy_mode_help',
                'Si el full ja té línies, tria si les vols afegir o substituir.',
              )}
            </p>
            <label className="flex items-center gap-2 text-sm">
              <input
                type="radio"
                name="copy-mode"
                checked={mode === 'append'}
                onChange={() => setMode('append')}
              />
              {t('projects.lines.copy_mode_append', 'Afegir al full actual')}
            </label>
            <label className="flex items-center gap-2 text-sm">
              <input
                type="radio"
                name="copy-mode"
                checked={mode === 'replace'}
                onChange={() => setMode('replace')}
              />
              {t('projects.lines.copy_mode_replace', 'Substituir el full actual')}
            </label>
          </div>
        ) : null}

        <div className="flex justify-end gap-2">
          <Button type="button" variant="outline" onClick={onClose} disabled={submitting}>
            {t('projects.lines.form.cancel', 'Cancel·lar')}
          </Button>
          <Button type="button" onClick={() => void handleCopy()} disabled={submitting || !selectedId}>
            {t('projects.lines.copy_confirm', 'Copiar línies')}
          </Button>
        </div>
      </div>
    </div>
  )
}
