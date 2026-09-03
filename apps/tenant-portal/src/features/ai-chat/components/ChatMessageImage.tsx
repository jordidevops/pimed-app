import { useEffect, useState } from 'react'
import { useTenant } from '@/contexts/TenantContext'
import { getFileUrl } from '@/features/storage/api/storageService'

type ChatMessageImageProps = {
  fileId: string
  alt?: string
  className?: string
}

export function ChatMessageImage({ fileId, alt, className }: ChatMessageImageProps) {
  const { activeTenant } = useTenant()
  const tenantId = activeTenant?.id ?? null
  const [url, setUrl] = useState<string | null>(null)
  const [failed, setFailed] = useState(false)

  useEffect(() => {
    if (!tenantId) return
    let cancelled = false

    void getFileUrl(fileId, 300, tenantId, false)
      .then((res) => {
        if (!cancelled) setUrl(res.url)
      })
      .catch(() => {
        if (!cancelled) setFailed(true)
      })

    return () => {
      cancelled = true
    }
  }, [fileId, tenantId])

  if (failed) {
    return (
      <div className="text-xs opacity-80 italic">
        [Imatge no disponible]
      </div>
    )
  }

  if (!url) {
    return <div className="h-32 w-48 rounded-lg bg-white/10 animate-pulse" />
  }

  return (
    <img
      src={url}
      alt={alt ?? 'Imatge adjunta'}
      className={className ?? 'max-h-64 rounded-lg border border-white/20 object-contain'}
    />
  )
}
