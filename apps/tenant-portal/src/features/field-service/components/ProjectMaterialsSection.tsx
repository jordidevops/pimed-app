import { useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Plus } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { addProjectMaterial, getProjectMaterials } from '../api/materialsService'

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
  const queryClient = useQueryClient()
  const [name, setName] = useState('')
  const [qty, setQty] = useState('1')
  const [unit, setUnit] = useState('')
  const [saving, setSaving] = useState(false)

  const { data: materials = [], isLoading } = useQuery({
    queryKey: ['project_materials', projectId],
    queryFn: () => getProjectMaterials(projectId),
    enabled: !!projectId,
  })

  async function handleAdd(e: React.FormEvent) {
    e.preventDefault()
    if (readOnly || !activeTenant?.id || !name.trim()) return

    setSaving(true)
    try {
      await addProjectMaterial({
        tenant_id: activeTenant.id,
        project_id: projectId,
        name: name.trim(),
        quantity: Number.parseFloat(qty) || 1,
        unit: unit.trim() || null,
        work_log_id: workLogId ?? null,
      })
      setName('')
      setQty('1')
      setUnit('')
      queryClient.invalidateQueries({ queryKey: ['project_materials', projectId] })
      toast({
        description: t('materials.added', 'Material afegit'),
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
      ) : materials.length === 0 ? (
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
