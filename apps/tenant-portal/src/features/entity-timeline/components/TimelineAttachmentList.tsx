import { useState } from 'react'
import { Download, Loader2 } from 'lucide-react'
import { useTenant } from '@/contexts/TenantContext'
import { getFileUrl } from '@/features/storage/api/storageService'
import type { CommentAttachment } from '../api/timelineService'

function formatBytes(bytes: number | null | undefined): string {
  if (!bytes || bytes <= 0) return ''
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

interface TimelineAttachmentListProps {
  attachments: CommentAttachment[]
}

export function TimelineAttachmentList({ attachments }: TimelineAttachmentListProps) {
  const { activeTenant } = useTenant()
  const [loadingId, setLoadingId] = useState<string | null>(null)

  if (!attachments.length) return null

  async function openAttachment(att: CommentAttachment) {
    if (!activeTenant?.id) return
    setLoadingId(att.file_id)
    try {
      const { url } = await getFileUrl(att.file_id, 3600, activeTenant.id, true)
      window.open(url, '_blank', 'noopener,noreferrer')
    } finally {
      setLoadingId(null)
    }
  }

  return (
    <ul className="flex flex-wrap gap-2 mt-2">
      {attachments.map((att) => (
        <li key={att.file_id}>
          <button
            type="button"
            onClick={() => void openAttachment(att)}
            disabled={loadingId === att.file_id}
            className="inline-flex items-center gap-1.5 rounded-md border border-border bg-muted/40 px-2 py-1 text-xs hover:bg-muted transition-colors"
          >
            {loadingId === att.file_id ? (
              <Loader2 className="h-3 w-3 animate-spin" />
            ) : (
              <Download className="h-3 w-3" />
            )}
            <span className="max-w-[180px] truncate">{att.name}</span>
            {att.size_bytes ? (
              <span className="text-muted-foreground">({formatBytes(att.size_bytes)})</span>
            ) : null}
          </button>
        </li>
      ))}
    </ul>
  )
}
