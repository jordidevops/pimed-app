import { useEffect, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Loader2, Plus, X } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useToast } from '@/hooks/use-toast'
import {
  useEmployeeTagAssignments,
  useEmployeeTags,
  useEnsureEmployeeTag,
  useSetEmployeeTags,
} from '../api/useEmployeeTags'

export function EmployeeTagsField({
  employeeId,
  canWrite,
}: {
  employeeId: string
  canWrite: boolean
}) {
  const { t } = useTranslation('employees')
  const { toast } = useToast()
  const { data: allTags = [] } = useEmployeeTags(true)
  const { data: assignments = [], isLoading } = useEmployeeTagAssignments(employeeId)
  const setTags = useSetEmployeeTags(employeeId)
  const ensureTag = useEnsureEmployeeTag()
  const [selected, setSelected] = useState<string[]>([])
  const [draft, setDraft] = useState('')
  const [dirty, setDirty] = useState(false)

  useEffect(() => {
    setSelected(assignments.map((a) => a.tag_id).filter(Boolean) as string[])
    setDirty(false)
  }, [assignments])

  const selectedTags = useMemo(
    () => allTags.filter((tag) => tag.id && selected.includes(tag.id)),
    [allTags, selected],
  )

  const available = useMemo(
    () => allTags.filter((tag) => tag.id && !selected.includes(tag.id)),
    [allTags, selected],
  )

  async function save(next: string[]) {
    try {
      await setTags.mutateAsync(next)
      setSelected(next)
      setDirty(false)
      toast({ title: t('employees.tags.saved', 'Etiquetes desades') })
    } catch (e) {
      toast({
        variant: 'destructive',
        title: t('employees.tags.save_failed', "No s'han pogut desar les etiquetes"),
        description: e instanceof Error ? e.message : undefined,
      })
    }
  }

  async function addNew() {
    const name = draft.trim()
    if (!name) return
    try {
      const tag = await ensureTag.mutateAsync(name)
      if (!tag.id) return
      const next = selected.includes(tag.id) ? selected : [...selected, tag.id]
      setDraft('')
      await save(next)
    } catch (e) {
      toast({
        variant: 'destructive',
        title: t('employees.tags.create_failed', "No s'ha pogut crear l'etiqueta"),
        description: e instanceof Error ? e.message : undefined,
      })
    }
  }

  if (isLoading) {
    return <div className="text-sm text-muted-foreground">{t('employees.tags.loading', 'Carregant etiquetes…')}</div>
  }

  return (
    <div className="space-y-2 rounded-lg border border-border p-3">
      <label className="text-sm font-medium">{t('employees.tags.label', 'Etiquetes')}</label>
      <div className="flex flex-wrap gap-1.5 min-h-[1.75rem]">
        {selectedTags.length === 0 ? (
          <span className="text-xs text-muted-foreground">
            {t('employees.tags.empty', 'Sense etiquetes')}
          </span>
        ) : (
          selectedTags.map((tag) => (
            <span
              key={tag.id}
              className="inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-xs bg-muted/40"
            >
              {tag.name}
              {canWrite ? (
                <button
                  type="button"
                  className="text-muted-foreground hover:text-foreground"
                  onClick={() => {
                    const next = selected.filter((id) => id !== tag.id)
                    setSelected(next)
                    setDirty(true)
                  }}
                  aria-label={t('employees.tags.remove', 'Treure')}
                >
                  <X className="h-3 w-3" />
                </button>
              ) : null}
            </span>
          ))
        )}
      </div>

      {canWrite ? (
        <div className="space-y-2">
          {available.length > 0 ? (
            <select
              className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
              value=""
              onChange={(e) => {
                const id = e.target.value
                if (!id) return
                const next = [...selected, id]
                setSelected(next)
                setDirty(true)
              }}
            >
              <option value="">{t('employees.tags.add_existing', 'Afegir etiqueta…')}</option>
              {available.map((tag) => (
                <option key={tag.id!} value={tag.id!}>
                  {tag.name}
                </option>
              ))}
            </select>
          ) : null}

          <div className="flex gap-2">
            <Input
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              placeholder={t('employees.tags.new_placeholder', 'Nova etiqueta')}
              onKeyDown={(e) => {
                if (e.key === 'Enter') {
                  e.preventDefault()
                  void addNew()
                }
              }}
            />
            <Button type="button" variant="outline" size="sm" disabled={!draft.trim() || ensureTag.isPending} onClick={() => void addNew()}>
              {ensureTag.isPending ? <Loader2 className="h-4 w-4 animate-spin" /> : <Plus className="h-4 w-4" />}
            </Button>
          </div>

          {dirty ? (
            <Button type="button" size="sm" disabled={setTags.isPending} onClick={() => void save(selected)}>
              {setTags.isPending ? <Loader2 className="h-4 w-4 animate-spin mr-1" /> : null}
              {t('employees.tags.save', 'Desar etiquetes')}
            </Button>
          ) : null}
        </div>
      ) : null}
    </div>
  )
}
