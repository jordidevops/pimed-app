import { useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Plus } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { useToast } from '@/hooks/use-toast'
import {
  addProjectExpense,
  getProjectExpenses,
  type ProjectExpensePaidBy,
} from '../api/expensesService'

interface ProjectExpensesSectionProps {
  projectId: string
  readOnly?: boolean
  embedded?: boolean
}

function eurosToCents(raw: string): number | null {
  const trimmed = raw.trim().replace(',', '.')
  if (!trimmed) return null
  const n = Number(trimmed)
  if (!Number.isFinite(n) || n < 0) return Number.NaN
  return Math.round(n * 100)
}

function centsToEuros(cents: number): string {
  return (cents / 100).toFixed(2)
}

function formatError(err: unknown): string {
  if (!err) return 'unknown_error'
  if (typeof err === 'string') return err
  if (err instanceof Error && err.message) return err.message
  if (typeof err === 'object') {
    const o = err as Record<string, unknown>
    const parts = [
      typeof o.code === 'string' ? `code=${o.code}` : null,
      typeof o.message === 'string' ? o.message : null,
      typeof o.details === 'string' ? o.details : null,
    ].filter(Boolean)
    if (parts.length > 0) return parts.join(' · ')
  }
  try {
    return JSON.stringify(err)
  } catch {
    return String(err)
  }
}

export function ProjectExpensesSection({
  projectId,
  readOnly = false,
  embedded = false,
}: ProjectExpensesSectionProps) {
  const { t } = useTranslation('field-service')
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const [description, setDescription] = useState('')
  const [amount, setAmount] = useState('')
  const [isBillable, setIsBillable] = useState(false)
  const [paidBy, setPaidBy] = useState<ProjectExpensePaidBy>('company')
  const [saving, setSaving] = useState(false)

  const { data: expenses = [], isLoading } = useQuery({
    queryKey: ['project_expenses', projectId],
    queryFn: () => getProjectExpenses(projectId),
    enabled: !!projectId,
  })

  async function handleAdd(e: React.FormEvent) {
    e.preventDefault()
    if (readOnly || !description.trim()) return
    const cents = eurosToCents(amount)
    if (cents == null || Number.isNaN(cents)) {
      toast({
        variant: 'destructive',
        title: t('expenses.amount_invalid', 'Import no vàlid'),
      })
      return
    }
    setSaving(true)
    try {
      await addProjectExpense({
        project_id: projectId,
        description: description.trim(),
        amount_cents: cents,
        is_billable: isBillable,
        paid_by: paidBy,
      })
      setDescription('')
      setAmount('')
      setIsBillable(false)
      setPaidBy('company')
      void queryClient.invalidateQueries({ queryKey: ['project_expenses', projectId] })
      toast({
        description: t('expenses.added', 'Despesa desada'),
      })
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('expenses.add_failed', 'No s’ha pogut afegir la despesa'),
        description: formatError(err),
      })
    } finally {
      setSaving(false)
    }
  }

  return (
    <section className="space-y-3">
      {!embedded && (
        <div>
          <h3 className="text-sm font-semibold">{t('expenses.title', 'Despeses')}</h3>
          <p className="text-xs text-muted-foreground">
            {readOnly
              ? t(
                  'expenses.hint_readonly',
                  'La visita té el part publicat; les despeses són només de lectura.',
                )
              : t(
                  'expenses.hint',
                  'Registra un import de la feina i indica si és imputable al client i qui l’ha pagat.',
                )}
          </p>
        </div>
      )}

      {isLoading ? (
        <div className="h-12 animate-pulse rounded-lg bg-accent/40" />
      ) : expenses.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          {t('expenses.empty', 'Cap despesa registrada')}
        </p>
      ) : (
        <ul className="space-y-2">
          {expenses.map((item) => (
            <li
              key={item.id}
              className="flex flex-wrap items-center justify-between gap-2 rounded-lg border border-border px-3 py-2 text-sm"
            >
              <span className="min-w-0 font-medium">{item.description}</span>
              <span className="tabular-nums text-muted-foreground">
                {centsToEuros(item.amount_cents)} €
              </span>
              <div className="flex flex-wrap gap-1">
                {item.is_billable ? (
                  <Badge variant="secondary">
                    {t('expenses.billable', 'Imputable')}
                  </Badge>
                ) : (
                  <Badge variant="outline">
                    {t('expenses.not_billable', 'No imputable')}
                  </Badge>
                )}
                <Badge variant="outline">
                  {item.paid_by === 'employee'
                    ? t('expenses.paid_by_employee', 'Paga empleat')
                    : t('expenses.paid_by_company', 'Paga empresa')}
                </Badge>
              </div>
            </li>
          ))}
        </ul>
      )}

      {!readOnly && (
        <form onSubmit={handleAdd} className="grid gap-2 sm:grid-cols-[1fr_100px_auto]">
          <Input
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            placeholder={t('expenses.description', 'Descripció')}
            required
          />
          <Input
            inputMode="decimal"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            placeholder={t('expenses.amount', 'Import €')}
            required
          />
          <Button type="submit" size="sm" disabled={saving} className="gap-1">
            <Plus className="h-4 w-4" />
            {saving ? t('expenses.saving', 'Desant…') : t('expenses.add', 'Afegir')}
          </Button>
          <label className="flex items-center gap-2 text-xs text-muted-foreground sm:col-span-2">
            <input
              type="checkbox"
              className="rounded border-border"
              checked={isBillable}
              onChange={(e) => setIsBillable(e.target.checked)}
            />
            {t('expenses.is_billable', 'Imputable al client')}
          </label>
          <label className="flex flex-col gap-1 text-xs text-muted-foreground">
            {t('expenses.paid_by', 'Qui paga')}
            <select
              className="h-9 rounded-md border border-input bg-background px-2 text-sm text-foreground"
              value={paidBy}
              onChange={(e) => setPaidBy(e.target.value as ProjectExpensePaidBy)}
            >
              <option value="company">
                {t('expenses.paid_by_company', 'Paga empresa')}
              </option>
              <option value="employee">
                {t('expenses.paid_by_employee', 'Paga empleat')}
              </option>
            </select>
          </label>
        </form>
      )}
    </section>
  )
}
