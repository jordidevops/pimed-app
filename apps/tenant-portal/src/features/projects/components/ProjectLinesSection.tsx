import { useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Plus, Trash2 } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { Button } from '@/components/ui/button'
import { useToast } from '@/hooks/use-toast'
import { ProjectLineForm } from './ProjectLineForm'
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

  const [addingLine, setAddingLine] = useState(false)
  const [editLine, setEditLine] = useState<ProjectLine | null>(null)

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
  }

  // ─── Render ─────────────────────────────────────────────────────────────────

  return (
    <div className="space-y-4">
      {/* Title row */}
      <div className="flex items-center justify-between">
        <h2 className="text-lg font-semibold text-foreground">
          {t('projects.lines.title', 'Pressupost')}
        </h2>
        {!addingLine && !editLine && (
          <Button size="sm" onClick={() => setAddingLine(true)}>
            <Plus className="h-4 w-4 mr-1.5" />
            {t('projects.lines.add_line', 'Afegir línia')}
          </Button>
        )}
      </div>

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
            {t('projects.lines.empty', 'No hi ha línies de pressupost')}
          </p>
        </div>
      ) : lines.length === 0 && !addingLine ? (
        <div className="flex flex-col items-center justify-center py-10 gap-2 border border-dashed border-border rounded-xl">
          <p className="text-sm text-muted-foreground">
            {t('projects.lines.empty', 'No hi ha línies de pressupost')}
          </p>
          <Button variant="outline" size="sm" onClick={() => setAddingLine(true)}>
            <Plus className="h-4 w-4 mr-1.5" />
            {t('projects.lines.add_line', 'Afegir línia')}
          </Button>
        </div>
      ) : lines.length > 0 ? (
        <div className="rounded-xl border border-border overflow-hidden">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-border bg-muted/40">
                <th className="text-left px-4 py-2.5 font-medium text-muted-foreground">
                  {t('projects.lines.columns.name', 'Descripció')}
                </th>
                <th className="text-right px-4 py-2.5 font-medium text-muted-foreground hidden sm:table-cell">
                  {t('projects.lines.columns.quantity', 'Qtd')}
                </th>
                <th className="text-left px-4 py-2.5 font-medium text-muted-foreground hidden md:table-cell">
                  {t('projects.lines.columns.unit', 'Unitat')}
                </th>
                <th className="text-right px-4 py-2.5 font-medium text-muted-foreground hidden sm:table-cell">
                  {t('projects.lines.columns.unit_price', 'Preu unit.')}
                </th>
                <th className="text-right px-4 py-2.5 font-medium text-muted-foreground hidden md:table-cell">
                  {t('projects.lines.columns.discount', 'Dte%')}
                </th>
                <th className="text-right px-4 py-2.5 font-medium text-muted-foreground hidden sm:table-cell">
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
                    editLine?.id === line.id ? 'bg-muted/30' : ''
                  }`}
                >
                  {editLine?.id === line.id ? (
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
                      <td className="px-4 py-2.5 text-right tabular-nums text-muted-foreground hidden sm:table-cell">
                        {line.quantity ?? '—'}
                      </td>
                      <td className="px-4 py-2.5 text-muted-foreground hidden md:table-cell">
                        {line.unit ?? '—'}
                      </td>
                      <td className="px-4 py-2.5 text-right tabular-nums text-muted-foreground hidden sm:table-cell">
                        {line.unit_price != null
                          ? moneyFmt.format(line.unit_price)
                          : '—'}
                      </td>
                      <td className="px-4 py-2.5 text-right text-muted-foreground hidden md:table-cell">
                        {line.discount_pct != null ? `${line.discount_pct}%` : '0%'}
                      </td>
                      <td className="px-4 py-2.5 text-right text-muted-foreground hidden sm:table-cell">
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
      ) : null}
    </div>
  )
}
