import { useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Plus, Trash2 } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { Button } from '@/components/ui/button'
import { useTenant } from '@/contexts/TenantContext'
import { ProjectLineForm } from './ProjectLineForm'
import { ApplyPricingTemplateDialog } from '@/features/commercial/components/ApplyPricingTemplateDialog'
import { CopyFromJobDialog } from '@/features/commercial/components/CopyFromJobDialog'
import { SaveAsHabitDialog } from '@/features/commercial/components/SaveAsHabitDialog'
import {
  cancelCommercialDocument,
  listProjectCommercialDocuments,
  rejectCommercialDocument,
} from '@/features/commercial/api/commercialFlowService'
import {
  commercialDocumentDivergesFromLiveTotal,
  liveProjectLinesTotalCents,
} from '@/features/commercial/utils/quotePriceDrift'
import { effectiveCommercialDocumentStatus } from '@/features/commercial/utils/pendingCommercialAction'
import type { Database } from '@/types/database.types'

type ProjectLine = Database['api']['Views']['project_lines']['Row']

const moneyFmt = new Intl.NumberFormat('ca-ES', {
  style: 'currency',
  currency: 'EUR',
})

// ─── Props ────────────────────────────────────────────────────────────────────

interface ProjectLinesSectionProps {
  projectId: string
}

// ─── ProjectLinesSection ──────────────────────────────────────────────────────

export function ProjectLinesSection({ projectId }: ProjectLinesSectionProps) {
  const { t } = useTranslation('projects')
  const queryClient = useQueryClient()
  const { toast } = useToast()
  const { activeRole } = useTenant()
  const canSaveHabit = activeRole === 'owner' || activeRole === 'manager'

  const [addingLine, setAddingLine] = useState(false)
  const [editLine, setEditLine] = useState<ProjectLine | null>(null)
  const [templateOpen, setTemplateOpen] = useState(false)
  const [copyOpen, setCopyOpen] = useState(false)
  const [habitOpen, setHabitOpen] = useState(false)
  const [quoteBusy, setQuoteBusy] = useState(false)

  const {
    data: lines = [],
    isLoading,
    error,
  } = useQuery<ProjectLine[]>({
    queryKey: ['project_lines', projectId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('project_lines')
        .select('*')
        .eq('project_id', projectId)
        .order('position', { ascending: true })
      if (error) throw error
      return data ?? []
    },
    enabled: !!projectId,
  })

  const { data: commercialDocs = [] } = useQuery({
    queryKey: ['commercial_documents', projectId],
    queryFn: () => listProjectCommercialDocuments(projectId),
    enabled: !!projectId,
  })

  const latestQuote = commercialDocs.find((doc) => doc.doc_type === 'quote')
  const latestQuoteStatus = latestQuote
    ? effectiveCommercialDocumentStatus(latestQuote)
    : null
  const liveCents = liveProjectLinesTotalCents(lines)
  const quoteDiverges =
    !!latestQuote &&
    commercialDocumentDivergesFromLiveTotal(Number(latestQuote.total), liveCents)
  const issuedQuoteDiverges = quoteDiverges && latestQuoteStatus === 'issued'
  const acceptedQuoteDiverges =
    quoteDiverges &&
    (latestQuoteStatus === 'accepted' || latestQuoteStatus === 'signed')

  // ─── Totals ─────────────────────────────────────────────────────────────────

  const totalSubtotal = lines.reduce((acc, l) => acc + (l.subtotal ?? 0), 0)
  const totalWithTax = lines.reduce((acc, l) => acc + (l.total_with_tax ?? 0), 0)

  // ─── Handlers ───────────────────────────────────────────────────────────────

  async function handleDelete(line: ProjectLine) {
    if (!line.id) return
    try {
      const { error } = await supabase.rpc('delete_project_line', { p_line_id: line.id })
      if (error) throw error
      queryClient.invalidateQueries({ queryKey: ['project_lines', projectId] })
      queryClient.invalidateQueries({ queryKey: ['commercial_documents', projectId] })
    } catch {
      toast({
        variant: 'destructive',
        title: t('projects.lines.errors.delete_failed', 'Error en eliminar la línia'),
      })
    }
  }

  function handleLineSaved() {
    setAddingLine(false)
    setEditLine(null)
    queryClient.invalidateQueries({ queryKey: ['project_lines', projectId] })
    queryClient.invalidateQueries({ queryKey: ['commercial_documents', projectId] })
  }

  // ─── Render ─────────────────────────────────────────────────────────────────

  return (
    <div className="space-y-4">
      {/* Title row */}
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <h2 className="text-lg font-semibold text-foreground">
            {t('projects.lines.title', 'Full de preus')}
          </h2>
          <p className="mt-1 text-sm text-muted-foreground">
            {t(
              'projects.lines.help',
              "Estimació interna de la feina. No es mostra al client fins que emetis un pressupost o un albarà.",
            )}
          </p>
        </div>
        {!addingLine && !editLine && (
          <div className="flex shrink-0 flex-col sm:flex-row gap-2">
            <Button size="sm" variant="outline" onClick={() => setCopyOpen(true)}>
              {t('projects.lines.copy_from_job', "Copiar d'una feina")}
            </Button>
            {canSaveHabit && lines.length > 0 ? (
              <Button size="sm" variant="outline" onClick={() => setHabitOpen(true)}>
                {t('projects.lines.save_as_habit', 'Desar com a servei habitual')}
              </Button>
            ) : null}
            <Button size="sm" variant="outline" onClick={() => setTemplateOpen(true)}>
              {t('projects.lines.apply_template', 'Servei habitual')}
            </Button>
            <Button size="sm" onClick={() => setAddingLine(true)}>
              <Plus className="h-4 w-4 mr-1.5" />
              {t('projects.lines.add_line', 'Afegir línia')}
            </Button>
          </div>
        )}
      </div>

      <ApplyPricingTemplateDialog
        projectId={projectId}
        open={templateOpen}
        onClose={() => setTemplateOpen(false)}
        onApplied={handleLineSaved}
      />
      <CopyFromJobDialog
        projectId={projectId}
        currentLineCount={lines.length}
        open={copyOpen}
        onClose={() => setCopyOpen(false)}
        onCopied={handleLineSaved}
      />
      <SaveAsHabitDialog
        projectId={projectId}
        open={habitOpen}
        onClose={() => setHabitOpen(false)}
      />

      {issuedQuoteDiverges && latestQuote ? (
        <div className="rounded-lg border border-amber-300 bg-amber-50 px-3 py-2 dark:border-amber-800 dark:bg-amber-950/30 space-y-2">
          <p className="text-sm font-medium">
            {t(
              'projects.commercial.price_drift_issued_title',
              'El full de preus ja no coincideix amb el pressupost emès',
            )}
          </p>
          <p className="text-xs text-muted-foreground">
            {t(
              'projects.commercial.price_drift_issued_help',
              'El client veu l’import del document. Per crear-ne un de nou, descarta o refusa l’actual.',
            )}
          </p>
          <div className="flex flex-wrap gap-2">
            <Button
              type="button"
              size="sm"
              variant="outline"
              disabled={quoteBusy}
              onClick={() => {
                void (async () => {
                  setQuoteBusy(true)
                  try {
                    await cancelCommercialDocument({ documentId: latestQuote.id })
                    toast({
                      title: t('projects.commercial.cancelled', 'Pressupost descartat'),
                    })
                    queryClient.invalidateQueries({ queryKey: ['commercial_documents', projectId] })
                  } catch (err) {
                    toast({
                      variant: 'destructive',
                      title: t('projects.commercial.error', 'Error comercial'),
                      description: err instanceof Error ? err.message : undefined,
                    })
                  } finally {
                    setQuoteBusy(false)
                  }
                })()
              }}
            >
              {t('projects.commercial.discard', 'Descartar')}
            </Button>
            <Button
              type="button"
              size="sm"
              variant="outline"
              disabled={quoteBusy}
              onClick={() => {
                void (async () => {
                  setQuoteBusy(true)
                  try {
                    await rejectCommercialDocument({ documentId: latestQuote.id })
                    toast({ title: t('projects.commercial.rejected', 'Refusat') })
                    queryClient.invalidateQueries({ queryKey: ['commercial_documents', projectId] })
                  } catch (err) {
                    toast({
                      variant: 'destructive',
                      title: t('projects.commercial.error', 'Error comercial'),
                      description: err instanceof Error ? err.message : undefined,
                    })
                  } finally {
                    setQuoteBusy(false)
                  }
                })()
              }}
            >
              {t('projects.commercial.reject', 'Refusar')}
            </Button>
          </div>
        </div>
      ) : null}

      {acceptedQuoteDiverges ? (
        <div className="rounded-lg border border-border bg-muted/40 px-3 py-2">
          <p className="text-sm font-medium">
            {t(
              'projects.commercial.price_drift_accepted_title',
              'El full intern no coincideix amb l’import autoritzat',
            )}
          </p>
          <p className="text-xs text-muted-foreground">
            {t(
              'projects.commercial.price_drift_accepted_help',
              'El pressupost acceptat no es descarta. Si cal, fes una ampliació o revisa les desviacions.',
            )}
          </p>
        </div>
      ) : null}

      {/* Inline add form */}
      {addingLine && (
        <div className="rounded-xl border border-border bg-card p-4">
          <ProjectLineForm
            projectId={projectId}
            onSaved={handleLineSaved}
            onCancel={() => setAddingLine(false)}
          />
        </div>
      )}

      {/* Lines */}
      {isLoading ? (
        <div className="flex items-center justify-center py-10">
          <div className="animate-spin rounded-full h-6 w-6 border-b-2 border-indigo-600" />
        </div>
      ) : error ? (
        <div className="bg-destructive/10 border border-destructive/30 rounded-xl p-4 text-center">
          <p className="text-sm text-destructive font-medium">
            {t('projects.lines.empty', "No hi ha línies d'imports")}
          </p>
        </div>
      ) : lines.length === 0 && !addingLine ? (
        <div className="flex flex-col items-center justify-center py-10 gap-2 border border-dashed border-border rounded-xl">
          <p className="text-sm text-muted-foreground">
            {t('projects.lines.empty', "No hi ha línies d'imports")}
          </p>
          <Button variant="outline" size="sm" onClick={() => setAddingLine(true)}>
            <Plus className="h-4 w-4 mr-1.5" />
            {t('projects.lines.add_line', 'Afegir línia')}
          </Button>
        </div>
      ) : lines.length > 0 ? (
        <>
          {/* Mobile cards — CF-2 */}
          <div className="space-y-2 sm:hidden">
            {lines.map((line) =>
              editLine != null && editLine.id != null && editLine.id === line.id ? (
                <div key={line.id} className="rounded-xl border border-border bg-card p-4">
                  <ProjectLineForm
                    projectId={projectId}
                    line={editLine}
                    onSaved={handleLineSaved}
                    onCancel={() => setEditLine(null)}
                  />
                </div>
              ) : (
                <div
                  key={line.id}
                  className="rounded-xl border border-border bg-card p-4 space-y-2"
                >
                  <div className="flex items-start justify-between gap-2">
                    <button
                      type="button"
                      className="text-left font-medium text-foreground hover:underline"
                      onClick={() => setEditLine(line)}
                    >
                      {line.name}
                    </button>
                    <button
                      type="button"
                      title={t('projects.lines.delete_line', 'Eliminar línia')}
                      onClick={() => handleDelete(line)}
                      className="p-1.5 rounded-lg hover:bg-destructive/10 text-muted-foreground hover:text-destructive"
                    >
                      <Trash2 className="h-4 w-4" />
                    </button>
                  </div>
                  <div className="flex flex-wrap gap-x-3 gap-y-1 text-sm text-muted-foreground tabular-nums">
                    <span>
                      {line.quantity ?? '—'} {line.unit ?? ''}
                    </span>
                    <span>
                      {line.unit_price != null ? moneyFmt.format(line.unit_price) : '—'}
                    </span>
                    {(line.discount_pct ?? 0) > 0 && <span>−{line.discount_pct}%</span>}
                  </div>
                  <div className="flex justify-between text-sm">
                    <span className="text-muted-foreground">
                      {t('projects.lines.columns.total', 'Total')}
                    </span>
                    <span className="font-semibold tabular-nums text-foreground">
                      {line.total_with_tax != null ? moneyFmt.format(line.total_with_tax) : '—'}
                    </span>
                  </div>
                </div>
              ),
            )}
            <div className="rounded-xl border border-border bg-muted/20 px-4 py-3 space-y-1">
              <div className="flex justify-between text-sm text-muted-foreground">
                <span>{t('projects.lines.totals.subtotal', 'Subtotal (sense IVA)')}</span>
                <span className="tabular-nums font-medium text-foreground">
                  {moneyFmt.format(totalSubtotal)}
                </span>
              </div>
              <div className="flex justify-between text-sm font-semibold text-foreground">
                <span>{t('projects.lines.totals.total', 'Total (amb IVA)')}</span>
                <span className="tabular-nums">{moneyFmt.format(totalWithTax)}</span>
              </div>
            </div>
          </div>

          {/* Desktop table */}
          <div className="rounded-xl border border-border overflow-hidden hidden sm:block">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-border bg-muted/40">
                <th className="text-left px-4 py-2.5 font-medium text-muted-foreground">
                  {t('projects.lines.columns.name', 'Descripció')}
                </th>
                <th className="text-right px-4 py-2.5 font-medium text-muted-foreground">
                  {t('projects.lines.columns.quantity', 'Qtd')}
                </th>
                <th className="text-left px-4 py-2.5 font-medium text-muted-foreground hidden md:table-cell">
                  {t('projects.lines.columns.unit', 'Unitat')}
                </th>
                <th className="text-right px-4 py-2.5 font-medium text-muted-foreground">
                  {t('projects.lines.columns.unit_price', 'Preu unit.')}
                </th>
                <th className="text-right px-4 py-2.5 font-medium text-muted-foreground hidden md:table-cell">
                  {t('projects.lines.columns.discount', 'Dte%')}
                </th>
                <th className="text-right px-4 py-2.5 font-medium text-muted-foreground">
                  {t('projects.lines.columns.tax_rate', 'IVA%')}
                </th>
                <th className="text-right px-4 py-2.5 font-medium text-muted-foreground">
                  {t('projects.lines.columns.subtotal', 'Subtotal')}
                </th>
                <th className="text-right px-4 py-2.5 font-medium text-muted-foreground">
                  {t('projects.lines.columns.total', 'Total')}
                </th>
                <th className="w-10" />
              </tr>
            </thead>
            <tbody className="divide-y divide-border">
              {lines.map((line) => (
                <tr
                  key={line.id}
                  className={`hover:bg-muted/20 transition-colors ${
                    editLine != null && editLine.id != null && editLine.id === line.id
                      ? 'bg-muted/30'
                      : ''
                  }`}
                >
                  {editLine != null &&
                  editLine.id != null &&
                  editLine.id === line.id ? (
                    <td colSpan={9} className="px-4 py-3">
                      <ProjectLineForm
                        projectId={projectId}
                        line={editLine}
                        onSaved={handleLineSaved}
                        onCancel={() => setEditLine(null)}
                      />
                    </td>
                  ) : (
                    <>
                      <td className="px-4 py-2.5 text-foreground font-medium">
                        <button
                          type="button"
                          className="text-left hover:underline"
                          onClick={() => setEditLine(line)}
                        >
                          {line.name}
                          {line.catalog_item_sku && (
                            <span className="ml-1.5 text-xs text-muted-foreground font-mono">
                              {line.catalog_item_sku}
                            </span>
                          )}
                        </button>
                      </td>
                      <td className="px-4 py-2.5 text-right tabular-nums text-muted-foreground">
                        {line.quantity ?? '—'}
                      </td>
                      <td className="px-4 py-2.5 text-muted-foreground hidden md:table-cell">
                        {line.unit ?? '—'}
                      </td>
                      <td className="px-4 py-2.5 text-right tabular-nums text-muted-foreground">
                        {line.unit_price != null
                          ? moneyFmt.format(line.unit_price)
                          : '—'}
                      </td>
                      <td className="px-4 py-2.5 text-right text-muted-foreground hidden md:table-cell">
                        {line.discount_pct != null ? `${line.discount_pct}%` : '0%'}
                      </td>
                      <td className="px-4 py-2.5 text-right text-muted-foreground">
                        {line.tax_rate != null ? `${line.tax_rate}%` : '—'}
                      </td>
                      <td className="px-4 py-2.5 text-right tabular-nums text-muted-foreground">
                        {line.subtotal != null ? moneyFmt.format(line.subtotal) : '—'}
                      </td>
                      <td className="px-4 py-2.5 text-right tabular-nums font-medium text-foreground">
                        {line.total_with_tax != null
                          ? moneyFmt.format(line.total_with_tax)
                          : '—'}
                      </td>
                      <td className="px-2 py-2.5 text-right">
                        <button
                          type="button"
                          title={t('projects.lines.delete_line', 'Eliminar línia')}
                          onClick={() => handleDelete(line)}
                          className="p-1.5 rounded-lg hover:bg-destructive/10 text-muted-foreground hover:text-destructive transition-colors"
                        >
                          <Trash2 className="h-4 w-4" />
                        </button>
                      </td>
                    </>
                  )}
                </tr>
              ))}
            </tbody>

            {/* Totals footer */}
            <tfoot>
              <tr className="border-t border-border bg-muted/20">
                <td
                  colSpan={6}
                  className="px-4 py-2.5 text-right text-sm text-muted-foreground font-medium"
                >
                  {t('projects.lines.totals.subtotal', 'Subtotal (sense IVA)')}
                </td>
                <td className="px-4 py-2.5 text-right tabular-nums font-semibold text-foreground">
                  {moneyFmt.format(totalSubtotal)}
                </td>
                <td colSpan={2} />
              </tr>
              <tr className="border-t border-border">
                <td
                  colSpan={6}
                  className="px-4 py-2.5 text-right text-sm font-semibold text-foreground"
                >
                  {t('projects.lines.totals.total', 'Total (amb IVA)')}
                </td>
                <td className="px-4 py-2.5 text-right tabular-nums font-bold text-foreground text-base">
                  {moneyFmt.format(totalWithTax)}
                </td>
                <td colSpan={2} />
              </tr>
            </tfoot>
          </table>
          </div>
        </>
      ) : null}
    </div>
  )
}
