import { useEffect, useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useToast } from '@/hooks/use-toast'
import { createPricingTemplateFromProject } from '../api/commercialFlowService'
import { rpcErrorMessage } from '../utils/rpcError'

interface SaveAsHabitDialogProps {
  projectId: string
  defaultName?: string
  open: boolean
  onClose: () => void
}

export function SaveAsHabitDialog({
  projectId,
  defaultName,
  open,
  onClose,
}: SaveAsHabitDialogProps) {
  const { t } = useTranslation('projects')
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const [name, setName] = useState(defaultName ?? '')
  const [category, setCategory] = useState('')
  const [createCatalog, setCreateCatalog] = useState(false)
  const [submitting, setSubmitting] = useState(false)

  useEffect(() => {
    if (!open) return
    setName(defaultName ?? '')
    setCategory('')
    setCreateCatalog(false)
  }, [open, defaultName])

  if (!open) return null

  async function handleSave() {
    if (!name.trim()) return
    setSubmitting(true)
    try {
      const result = await createPricingTemplateFromProject({
        projectId,
        name: name.trim(),
        category: category.trim() || null,
        unmatchedMode: createCatalog ? 'create_catalog' : 'skip',
      })
      await queryClient.invalidateQueries({ queryKey: ['pricing_templates'] })
      const skipped = result.skipped?.length ?? 0
      toast({
        title: t('projects.lines.save_as_habit_success', 'Servei habitual desat'),
        description:
          skipped > 0
            ? t('projects.lines.save_as_habit_skipped', "S'han omès línies sense catàleg")
            : undefined,
      })
      onClose()
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('projects.lines.save_as_habit_failed', "No s'ha pogut desar el servei"),
        description: rpcErrorMessage(err) || undefined,
      })
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <div className="fixed inset-0 z-50 flex items-end sm:items-center justify-center bg-black/40 p-0 sm:p-4">
      <div className="w-full max-w-lg rounded-t-2xl sm:rounded-xl border border-border bg-background p-4 sm:p-6 shadow-lg">
        <h3 className="text-lg font-semibold text-foreground mb-1">
          {t('projects.lines.save_as_habit_title', 'Desar aquest full com a servei habitual')}
        </h3>
        <p className="text-sm text-muted-foreground mb-4">
          {t(
            'projects.lines.save_as_habit_help',
            "Es desarà al catàleg amb el PVP vigent i les checklists d'aquesta OS. En aplicar-lo a una feina nova, els preus seran els del catàleg.",
          )}
        </p>

        <label className="mb-1.5 block text-sm font-medium">
          {t('projects.lines.save_as_habit_name', 'Nom del servei')}
        </label>
        <Input
          value={name}
          onChange={(e) => setName(e.target.value)}
          className="mb-3"
        />

        <label className="mb-1.5 block text-sm font-medium">
          {t('projects.lines.save_as_habit_category', 'Categoria (opcional)')}
        </label>
        <Input
          value={category}
          onChange={(e) => setCategory(e.target.value)}
          className="mb-3"
        />

        <label className="mb-4 flex items-start gap-2 text-sm">
          <input
            type="checkbox"
            className="mt-1"
            checked={createCatalog}
            onChange={(e) => setCreateCatalog(e.target.checked)}
          />
          <span>
            {t(
              'projects.lines.save_as_habit_create_catalog',
              'Crear ítems de catàleg per a línies lliures sense coincidència',
            )}
          </span>
        </label>

        <div className="flex justify-end gap-2">
          <Button type="button" variant="outline" onClick={onClose} disabled={submitting}>
            {t('projects.lines.form.cancel', 'Cancel·lar')}
          </Button>
          <Button
            type="button"
            onClick={() => void handleSave()}
            disabled={submitting || !name.trim()}
          >
            {t('projects.lines.save_as_habit_confirm', 'Desar servei')}
          </Button>
        </div>
      </div>
    </div>
  )
}
