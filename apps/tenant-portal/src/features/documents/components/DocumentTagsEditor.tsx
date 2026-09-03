import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { X, Plus, Tag } from 'lucide-react'
import { useTenant } from '@/contexts/TenantContext'
import { useDocumentTags } from '../api/useDocumentTags'
import { useDocumentTagAssignments } from '../api/useDocumentTagAssignments'
import { useAssignDocumentTags, useCreateDocumentTag } from '../api/useTagMutations'

const PRESET_COLORS = [
  '#6b7280', '#ef4444', '#f97316', '#eab308',
  '#22c55e', '#3b82f6', '#8b5cf6', '#ec4899',
]

function tagColorClass(color?: string | null): string {
  switch ((color ?? '').toLowerCase()) {
    case '#ef4444':
      return 'bg-red-500'
    case '#f97316':
      return 'bg-orange-500'
    case '#eab308':
      return 'bg-yellow-500'
    case '#22c55e':
      return 'bg-green-500'
    case '#3b82f6':
      return 'bg-blue-500'
    case '#8b5cf6':
      return 'bg-violet-500'
    case '#ec4899':
      return 'bg-pink-500'
    case '#6b7280':
    default:
      return 'bg-gray-500'
  }
}

interface DocumentTagsEditorProps {
  documentId: string
  canWrite: boolean
}

export function DocumentTagsEditor({ documentId, canWrite }: DocumentTagsEditorProps) {
  const { t } = useTranslation('documents')
  const { activeTenant } = useTenant()
  const { data: allTags = [] } = useDocumentTags()
  const { data: assignments = [] } = useDocumentTagAssignments(documentId)
  const assignMutation = useAssignDocumentTags(documentId)
  const createTagMutation = useCreateDocumentTag()

  const [pickerOpen, setPickerOpen] = useState(false)
  const [newTagName, setNewTagName] = useState('')
  const [newTagColor, setNewTagColor] = useState(PRESET_COLORS[5])

  const assignedTagIds = new Set(assignments.map((a) => a.tag_id!))
  const assignedTags = allTags.filter((t) => assignedTagIds.has(t.id!))

  async function toggleTag(tagId: string) {
    if (!canWrite) return
    const next = assignedTagIds.has(tagId)
      ? [...assignedTagIds].filter((id) => id !== tagId)
      : [...assignedTagIds, tagId]
    await assignMutation.mutateAsync(next)
  }

  async function handleCreateTag() {
    if (!newTagName.trim() || !activeTenant?.id) return
    const tag = await createTagMutation.mutateAsync({
      tenant_id: activeTenant.id,
      name: newTagName.trim(),
      color: newTagColor,
    })
    if (tag?.id) {
      await assignMutation.mutateAsync([...assignedTagIds, tag.id])
    }
    setNewTagName('')
    setNewTagColor(PRESET_COLORS[5])
  }

  return (
    <div className="flex items-center gap-1 flex-wrap">
      {/* Assigned tags */}
      {assignedTags.map((tag) => (
        <span
          key={tag.id}
          className={`inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium text-white ${tagColorClass(tag.color)}`}
        >
          {tag.name}
          {canWrite && (
            <button
              type="button"
              onClick={() => toggleTag(tag.id!)}
              className="opacity-70 hover:opacity-100 ml-0.5"
              title={t('tags.remove', 'Treure etiqueta')}
              aria-label={t('tags.remove', 'Treure etiqueta')}
            >
              <X className="h-2.5 w-2.5" />
            </button>
          )}
        </span>
      ))}

      {/* Add tag button */}
      {canWrite && (
        <div className="relative">
          <button
            type="button"
            onClick={() => setPickerOpen((v) => !v)}
            className="inline-flex items-center gap-0.5 px-2 py-0.5 rounded-full text-xs text-muted-foreground border border-dashed hover:border-primary hover:text-primary transition-colors"
            title={t('tags.openPicker', 'Obrir selector d\'etiquetes')}
            aria-label={t('tags.openPicker', 'Obrir selector d\'etiquetes')}
          >
            <Tag className="h-3 w-3" />
            <Plus className="h-2.5 w-2.5" />
          </button>

          {pickerOpen && (
            <div className="absolute left-0 top-6 z-50 bg-popover border rounded-lg shadow-md p-3 w-56 space-y-2">
              {/* Existing tags */}
              <div className="space-y-1 max-h-32 overflow-y-auto">
                {allTags.map((tag) => (
                  <button
                    key={tag.id}
                    type="button"
                    onClick={() => toggleTag(tag.id!)}
                    className={`w-full flex items-center gap-2 px-2 py-1 rounded text-sm hover:bg-accent transition-colors ${assignedTagIds.has(tag.id!) ? 'font-medium' : ''}`}
                  >
                    <span
                      className={`h-3 w-3 rounded-full shrink-0 ${tagColorClass(tag.color)}`}
                    />
                    {tag.name}
                    {assignedTagIds.has(tag.id!) && (
                      <span className="ml-auto text-primary text-xs">✓</span>
                    )}
                  </button>
                ))}
                {allTags.length === 0 && (
                  <p className="text-xs text-muted-foreground text-center py-2">
                    {t('tags.noTags', 'Sense etiquetes')}
                  </p>
                )}
              </div>

              {/* Create new tag */}
              <div className="border-t pt-2 space-y-1.5">
                <p className="text-xs font-medium text-muted-foreground">
                  {t('tags.createNew', 'Nova etiqueta')}
                </p>
                <input
                  type="text"
                  value={newTagName}
                  onChange={(e) => setNewTagName(e.target.value)}
                  onKeyDown={(e) => e.key === 'Enter' && handleCreateTag()}
                  placeholder={t('tags.namePlaceholder', 'Nom...')}
                  className="w-full rounded border border-input bg-background px-2 py-1 text-xs focus:outline-none focus:ring-1 focus:ring-ring"
                />
                <div className="flex gap-1 flex-wrap">
                  {PRESET_COLORS.map((c) => (
                    <button
                      key={c}
                      type="button"
                      onClick={() => setNewTagColor(c)}
                      className={`h-4 w-4 rounded-full transition-transform ${tagColorClass(c)} ${newTagColor === c ? 'ring-2 ring-offset-1 ring-foreground scale-110' : ''}`}
                      title={t('tags.pickColor', 'Seleccionar color')}
                      aria-label={t('tags.pickColor', 'Seleccionar color')}
                    />
                  ))}
                </div>
                <button
                  type="button"
                  disabled={!newTagName.trim() || createTagMutation.isPending}
                  onClick={handleCreateTag}
                  className="w-full text-xs bg-primary text-primary-foreground rounded px-2 py-1 disabled:opacity-50"
                >
                  {t('tags.create', 'Crear i assignar')}
                </button>
              </div>

              {/* Close */}
              <button
                type="button"
                onClick={() => setPickerOpen(false)}
                className="absolute top-2 right-2 text-muted-foreground hover:text-foreground"
                title={t('common.close', 'Tancar')}
                aria-label={t('common.close', 'Tancar')}
              >
                <X className="h-3.5 w-3.5" />
              </button>
            </div>
          )}
        </div>
      )}
    </div>
  )
}
