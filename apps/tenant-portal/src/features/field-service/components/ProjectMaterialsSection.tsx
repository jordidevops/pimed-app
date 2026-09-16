import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Plus, X } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { getProjectMaterials } from '../api/materialsService'
import { enqueueProjectMaterial } from '../api/fieldActualsQueue'
import { useProjectFieldOps } from '../hooks/useProjectFieldOps'
import { Badge } from '@/components/ui/badge'

interface ProjectMaterialsSectionProps {
  projectId: string
  workLogId?: string | null
  readOnly?: boolean
  embedded?: boolean
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
      typeof o.hint === 'string' ? `hint=${o.hint}` : null,
    ].filter(Boolean)
    if (parts.length > 0) return parts.join(' · ')
  }
  try {
    return JSON.stringify(err)
  } catch {
    return String(err)
  }
}

export function ProjectMaterialsSection({
  projectId,
  workLogId,
  readOnly = false,
  embedded = false,
}: ProjectMaterialsSectionProps) {
  const { t } = useTranslation('field-service')
  const { toast } = useToast()
  const { activeTenant } = useTenant()
  const localOps = useProjectFieldOps(activeTenant?.id, projectId)
  const [name, setName] = useState('')
  const [qty, setQty] = useState('1')
  const [unit, setUnit] = useState('')
  const [saving, setSaving] = useState(false)

  const { data: materials = [], isLoading } = useQuery({
    queryKey: ['project_materials', projectId],
    queryFn: () => getProjectMaterials(projectId, activeTenant?.id),
    enabled: !!projectId,
  })

  async function handleAdd(e: React.FormEvent) {
    e.preventDefault()
    if (readOnly || !activeTenant?.id || !name.trim()) return

    setSaving(true)
    try {
      const localWorklog = localOps.ops.find(
        (op) => op.kind === 'worklog.start' && op.id === workLogId,
      )
      await enqueueProjectMaterial({
        tenantId: activeTenant.id,
        projectId,
        name: name.trim(),
        quantity: Number.parseFloat(qty) || 1,
        unit: unit.trim() || undefined,
        workLogId: localWorklog ? undefined : workLogId ?? undefined,
        workLogClientOpId: localWorklog?.id,
        dependsOn: localWorklog ? [localWorklog.id] : undefined,
      })
      setName('')
      setQty('1')
      setUnit('')
      toast({
        description: t('closeout.offline.saved_locally', 'Desat al dispositiu · pendent de sincronitzar'),
      })
    } catch (err) {
      const detail = formatError(err)
      toast({
        variant: 'destructive',
        title: t('materials.add_failed', 'No s\'ha pogut afegir el material'),
        description: detail,
      })
    } finally {
      setSaving(false)
    }
  }

  return (
    <section className="space-y-3">
      {!embedded && (
        <div>
          <h3 className="text-sm font-semibold">{t('materials.title', 'Materials')}</h3>
          <p className="text-xs text-muted-foreground">
            {readOnly
              ? t(
                  'materials.hint_readonly',
                  'La visita té el part publicat; els materials són només de lectura.',
                )
              : t(
                  'materials.hint',
                  "Omple el formulari i prem Afegir per desar-lo a l'ordre.",
                )}
          </p>
        </div>
      )}

      {isLoading ? (
        <div className="h-12 animate-pulse rounded-lg bg-accent/40" />
      ) : materials.length === 0 && localOps.materials.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          {t('materials.empty', 'Cap material registrat')}
        </p>
      ) : (
        <ul className="space-y-2">
          {materials.map((item) => (
            <li
              key={item.id}
              className="flex items-center justify-between rounded-lg border border-border px-3 py-2 text-sm"
            >
              <span className="font-medium">{item.name}</span>
              <span className="text-muted-foreground">
                {item.quantity}
                {item.unit ? ` ${item.unit}` : ''}
              </span>
            </li>
          ))}
          {localOps.materials.map(({ op, payload }) => (
            <li
              key={op.id}
              className="flex items-center justify-between gap-2 rounded-lg border border-dashed border-amber-500/50 px-3 py-2 text-sm"
            >
              <span className="min-w-0 font-medium">{payload.name}</span>
              <span className="ml-auto text-muted-foreground">
                {payload.quantity}
                {payload.unit ? ` ${payload.unit}` : ''}
              </span>
              <Badge variant="secondary">
                {op.status === 'quarantined'
                  ? t('closeout.offline.action_required', 'Cal revisar')
                  : t('closeout.offline.pending_sync', 'Pendent de sincronitzar')}
              </Badge>
              {!readOnly && op.status !== 'syncing' && (
                <Button
                  type="button"
                  size="icon"
                  variant="ghost"
                  className="h-7 w-7"
                  aria-label={t('materials.cancel_pending', 'Cancel·lar material pendent')}
                  onClick={() => void localOps.removeLocalOp(op.id)}
                >
                  <X className="h-3.5 w-3.5" />
                </Button>
              )}
            </li>
          ))}
        </ul>
      )}

      {!readOnly && (
        <form onSubmit={handleAdd} className="grid gap-2 sm:grid-cols-[1fr_80px_80px_auto]">
          <Input
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder={t('materials.name', 'Material')}
            required
          />
          <Input
            type="number"
            min="0"
            step="any"
            value={qty}
            onChange={(e) => setQty(e.target.value)}
            placeholder={t('materials.qty', 'Quantitat')}
          />
          <Input
            value={unit}
            onChange={(e) => setUnit(e.target.value)}
            placeholder={t('materials.unit', 'Unitat')}
          />
          <Button type="submit" size="sm" disabled={saving} className="gap-1">
            <Plus className="h-4 w-4" />
            {saving ? t('materials.saving', 'Desant…') : t('materials.add', 'Afegir')}
          </Button>
        </form>
      )}
    </section>
  )
}
