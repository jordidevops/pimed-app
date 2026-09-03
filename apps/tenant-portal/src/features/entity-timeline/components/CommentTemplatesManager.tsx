import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Pencil, Trash2 } from 'lucide-react'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { useToast } from '@/hooks/use-toast'
import {
  deleteCommentTemplate,
  listCommentTemplates,
  upsertCommentTemplate,
  type CommentTemplate,
  type EntityTimelineType,
} from '../api/timelineService'

const ENTITY_TYPES: Array<{ value: EntityTimelineType | ''; labelKey: string }> = [
  { value: '', labelKey: 'templates.scope_global' },
  { value: 'employee', labelKey: 'templates.scope_employee' },
  { value: 'contact', labelKey: 'templates.scope_contact' },
  { value: 'project', labelKey: 'templates.scope_project' },
  { value: 'document', labelKey: 'templates.scope_document' },
]

interface FormState {
  id: string | null
  title: string
  body: string
  entity_type: EntityTimelineType | ''
  default_is_task: boolean
  sort_order: number
}

const EMPTY_FORM: FormState = {
  id: null,
  title: '',
  body: '',
  entity_type: '',
  default_is_task: false,
  sort_order: 0,
}

interface CommentTemplatesManagerProps {
  enabled?: boolean
  onReset?: () => void
}

export function CommentTemplatesManager({ enabled = true, onReset }: CommentTemplatesManagerProps) {
  const { t } = useTranslation('activity')
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const [form, setForm] = useState<FormState>(EMPTY_FORM)
  const [deleteTarget, setDeleteTarget] = useState<CommentTemplate | null>(null)

  const { data: templates = [], isLoading } = useQuery({
    queryKey: ['comment-templates', 'all'],
    queryFn: () => listCommentTemplates(null),
    enabled,
    staleTime: 30_000,
  })

  useEffect(() => {
    if (!enabled) {
      setForm(EMPTY_FORM)
      setDeleteTarget(null)
      onReset?.()
    }
  }, [enabled, onReset])

  const invalidate = async () => {
    await queryClient.invalidateQueries({ queryKey: ['comment-templates'] })
  }

  const saveMutation = useMutation({
    mutationFn: () =>
      upsertCommentTemplate({
        id: form.id,
        title: form.title.trim(),
        body: form.body.trim(),
        entity_type: form.entity_type || null,
        default_is_task: form.default_is_task,
        sort_order: form.sort_order,
      }),
    onSuccess: async () => {
      await invalidate()
      setForm(EMPTY_FORM)
      toast({ description: t('templates.saved', 'Plantilla desada') })
    },
    onError: () => {
      toast({
        variant: 'destructive',
        description: t('templates.save_error', 'Error en desar la plantilla'),
      })
    },
  })

  const deleteMutation = useMutation({
    mutationFn: (id: string) => deleteCommentTemplate(id),
    onSuccess: async (_data, deletedId) => {
      await invalidate()
      setDeleteTarget(null)
      setForm((current) => (current.id === deletedId ? EMPTY_FORM : current))
      toast({ description: t('templates.deleted', 'Plantilla eliminada') })
    },
    onError: () => {
      toast({
        variant: 'destructive',
        description: t('templates.delete_error', 'Error en eliminar la plantilla'),
      })
    },
  })

  function startEdit(template: CommentTemplate) {
    setForm({
      id: template.id,
      title: template.title,
      body: template.body,
      entity_type: template.entity_type ?? '',
      default_is_task: template.default_is_task,
      sort_order: template.sort_order,
    })
  }

  const canSave = form.title.trim().length > 0 && form.body.trim().length > 0

  return (
    <>
      <form
        className="space-y-3 rounded-lg border border-border p-4"
        onSubmit={(e) => {
          e.preventDefault()
          if (canSave) saveMutation.mutate()
        }}
      >
        <p className="text-xs font-medium text-muted-foreground">
          {form.id
            ? t('templates.form_edit', 'Editar plantilla')
            : t('templates.form_new', 'Nova plantilla')}
        </p>
        <Input
          value={form.title}
          onChange={(e) => setForm((f) => ({ ...f, title: e.target.value }))}
          placeholder={t('templates.title_placeholder', 'Títol (nom curt)')}
          maxLength={120}
        />
        <textarea
          value={form.body}
          onChange={(e) => setForm((f) => ({ ...f, body: e.target.value }))}
          rows={4}
          placeholder={t('templates.body_placeholder', 'Text del comentari...')}
          className="w-full resize-y rounded-md border border-input bg-background px-3 py-2 text-sm min-h-[80px]"
        />
        <div className="flex flex-wrap items-center gap-3">
          <label className="flex items-center gap-2 text-xs">
            <span className="text-muted-foreground">{t('templates.scope', 'Àmbit')}</span>
            <select
              value={form.entity_type}
              onChange={(e) =>
                setForm((f) => ({
                  ...f,
                  entity_type: e.target.value as EntityTimelineType | '',
                }))
              }
              className="h-8 rounded-md border border-input bg-background px-2 text-xs"
            >
              {ENTITY_TYPES.map((opt) => (
                <option key={opt.value || 'global'} value={opt.value}>
                  {t(opt.labelKey, opt.value || 'Totes les entitats')}
                </option>
              ))}
            </select>
          </label>
          <label className="flex items-center gap-1.5 text-xs text-muted-foreground cursor-pointer">
            <input
              type="checkbox"
              checked={form.default_is_task}
              onChange={(e) => setForm((f) => ({ ...f, default_is_task: e.target.checked }))}
            />
            {t('templates.default_task', 'Tasca per defecte')}
          </label>
          <label className="flex items-center gap-2 text-xs">
            <span className="text-muted-foreground">{t('templates.sort_order', 'Ordre')}</span>
            <input
              type="number"
              value={form.sort_order}
              onChange={(e) =>
                setForm((f) => ({ ...f, sort_order: Number(e.target.value) || 0 }))
              }
              className="h-8 w-16 rounded-md border border-input bg-background px-2 text-xs"
            />
          </label>
        </div>
        <div className="flex gap-2">
          <Button type="submit" size="sm" disabled={!canSave || saveMutation.isPending}>
            {form.id ? t('templates.save', 'Desar') : t('templates.create', 'Crear')}
          </Button>
          {form.id && (
            <Button
              type="button"
              variant="ghost"
              size="sm"
              onClick={() => setForm(EMPTY_FORM)}
            >
              {t('templates.cancel_edit', 'Cancel·lar edició')}
            </Button>
          )}
        </div>
      </form>

      <div className="space-y-2 mt-6">
        <p className="text-xs font-medium text-muted-foreground">
          {t('templates.list_title', 'Plantilles existents')}
        </p>
        {isLoading && (
          <p className="text-sm text-muted-foreground">{t('timeline.loading', 'Carregant...')}</p>
        )}
        {!isLoading && templates.length === 0 && (
          <p className="text-sm text-muted-foreground">
            {t('templates.empty_manage', 'Encara no hi ha plantilles.')}
          </p>
        )}
        <ul className="space-y-1">
          {templates.map((template) => (
            <li
              key={template.id}
              className="flex items-center justify-between gap-2 rounded-md border border-border px-2 py-1.5 text-sm"
            >
              <div className="min-w-0 flex-1">
                <p className="font-medium truncate">{template.title}</p>
                <p className="text-[10px] text-muted-foreground truncate">
                  {template.entity_type
                    ? t(`templates.scope_${template.entity_type}`, template.entity_type)
                    : t('templates.scope_global', 'Totes les entitats')}
                  {template.default_is_task
                    ? ` · ${t('templates.task_badge', 'Tasca per defecte')}`
                    : ''}
                </p>
              </div>
              <div className="flex shrink-0 gap-1">
                <Button
                  type="button"
                  variant="ghost"
                  size="icon"
                  className="h-7 w-7"
                  title={t('templates.edit', 'Editar')}
                  onClick={() => startEdit(template)}
                >
                  <Pencil className="h-3.5 w-3.5" />
                </Button>
                <Button
                  type="button"
                  variant="ghost"
                  size="icon"
                  className="h-7 w-7 text-destructive"
                  title={t('templates.delete', 'Eliminar')}
                  onClick={() => setDeleteTarget(template)}
                >
                  <Trash2 className="h-3.5 w-3.5" />
                </Button>
              </div>
            </li>
          ))}
        </ul>
      </div>

      <Dialog open={deleteTarget !== null} onOpenChange={(v) => !v && setDeleteTarget(null)}>
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>{t('templates.delete_confirm_title', 'Eliminar plantilla')}</DialogTitle>
            <DialogDescription>
              {t(
                'templates.delete_confirm_description',
                'Vols eliminar la plantilla «{{title}}»?',
                { title: deleteTarget?.title ?? '' },
              )}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="ghost" onClick={() => setDeleteTarget(null)}>
              {t('common:common.cancel', 'Cancel·lar')}
            </Button>
            <Button
              variant="destructive"
              disabled={deleteMutation.isPending}
              onClick={() => deleteTarget && deleteMutation.mutate(deleteTarget.id)}
            >
              {t('templates.delete', 'Eliminar')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  )
}
