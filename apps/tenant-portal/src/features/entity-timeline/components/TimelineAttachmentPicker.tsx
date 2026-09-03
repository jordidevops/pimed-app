import { useState } from 'react'
import { Paperclip, X, Loader2 } from 'lucide-react'
import { useTranslation } from 'react-i18next'
import { useTenant } from '@/contexts/TenantContext'
import { uploadFile } from '@/features/storage/api/storageService'
import { StorageServiceError } from '@/features/storage/types/storage.types'
import type { EntityTimelineType } from '../api/timelineService'

export interface PendingAttachment {
  file_id: string
  name: string
  mime: string | null
  size_bytes: number
}

interface TimelineAttachmentPickerProps {
  entityType: EntityTimelineType
  entityId: string
  attachments: PendingAttachment[]
  onChange: (attachments: PendingAttachment[]) => void
  disabled?: boolean
}

export function TimelineAttachmentPicker({
  entityType,
  entityId,
  attachments,
  onChange,
  disabled,
}: TimelineAttachmentPickerProps) {
  const { t } = useTranslation('activity')
  const { activeTenant, tenantScopeReady } = useTenant()
  const [uploading, setUploading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function handleFilesSelected(files: FileList | null) {
    if (!files?.length || !activeTenant?.id || !tenantScopeReady) {
      if (!tenantScopeReady) {
        setError(t('timeline.attach_tenant_loading', 'Esperant el context del tenant...'))
      }
      return
    }
    setError(null)
    setUploading(true)

    const next = [...attachments]

    try {
      for (const file of Array.from(files)) {
        if (next.length >= 10) break

        const result = await uploadFile({
          tenant_id: activeTenant.id,
          file,
          storage_provider_id: null,
          metadata: {
            source: 'entity_comment',
            entity_type: entityType,
            entity_id: entityId,
          },
        })

        next.push({
          file_id: result.node_id,
          name: file.name,
          mime: file.type || null,
          size_bytes: result.size_bytes,
        })
      }
      onChange(next)
    } catch (err) {
      const message =
        err instanceof StorageServiceError
          ? err.message
          : err instanceof Error
            ? err.message
            : 'Error en pujar el fitxer'
      setError(message)
    } finally {
      setUploading(false)
    }
  }

  function removeAttachment(fileId: string) {
    onChange(attachments.filter((a) => a.file_id !== fileId))
  }

  return (
    <div className="space-y-2">
      <div className="flex items-center gap-2">
        <label
          className={`inline-flex items-center gap-1.5 text-xs text-muted-foreground cursor-pointer hover:text-foreground ${
            disabled || uploading ? 'opacity-50 pointer-events-none' : ''
          }`}
        >
          {uploading ? (
            <Loader2 className="h-3.5 w-3.5 animate-spin" />
          ) : (
            <Paperclip className="h-3.5 w-3.5" />
          )}
          {t('timeline.attach', 'Adjuntar')}
          <input
            type="file"
            className="sr-only"
            multiple
            disabled={disabled || uploading}
            onChange={(e) => {
              void handleFilesSelected(e.target.files)
              e.target.value = ''
            }}
          />
        </label>
      </div>

      {attachments.length > 0 && (
        <ul className="flex flex-wrap gap-2">
          {attachments.map((att) => (
            <li
              key={att.file_id}
              className="inline-flex items-center gap-1 rounded-md border border-border bg-muted/50 px-2 py-1 text-xs"
            >
              <span className="max-w-[160px] truncate">{att.name}</span>
              <button
                type="button"
                className="text-muted-foreground hover:text-foreground"
                onClick={() => removeAttachment(att.file_id)}
                disabled={disabled || uploading}
                aria-label="Eliminar adjunt"
              >
                <X className="h-3 w-3" />
              </button>
            </li>
          ))}
        </ul>
      )}

      {error && <p className="text-xs text-destructive">{error}</p>}
    </div>
  )
}
