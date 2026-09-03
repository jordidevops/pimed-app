import { useTranslation } from 'react-i18next'
import { Check } from 'lucide-react'
import type { MentionReadStatus } from '../api/timelineService'

interface MentionReadReceiptsProps {
  mentionsRead: MentionReadStatus[]
}

function formatReadAt(iso: string): string {
  const d = new Date(iso)
  return d.toLocaleString('ca-ES', {
    day: 'numeric',
    month: 'short',
    hour: '2-digit',
    minute: '2-digit',
  })
}

export function MentionReadReceipts({ mentionsRead }: MentionReadReceiptsProps) {
  const { t } = useTranslation('activity')

  if (mentionsRead.length === 0) return null

  const readCount = mentionsRead.filter((m) => m.read_at).length

  return (
    <div className="mt-2 rounded-md border border-border/60 bg-muted/30 px-2.5 py-2">
      <p className="text-[11px] font-medium text-muted-foreground mb-1.5">
        {t('read_receipts.title', 'Confirmació de lectura')}
        <span className="ml-1.5 font-normal">
          ({t('read_receipts.progress', '{{read}} de {{total}}', {
            read: readCount,
            total: mentionsRead.length,
          })})
        </span>
      </p>
      <ul className="space-y-1">
        {mentionsRead.map((m) => {
          const read = !!m.read_at
          return (
            <li
              key={m.id}
              className={`flex items-center gap-1.5 text-xs ${
                read ? 'text-foreground' : 'text-muted-foreground'
              }`}
            >
              {read ? (
                <Check className="h-3.5 w-3.5 shrink-0 text-green-600" aria-hidden />
              ) : (
                <span
                  className="h-3.5 w-3.5 shrink-0 rounded-full border border-muted-foreground/40"
                  aria-hidden
                />
              )}
              <span className="font-medium">{m.full_name ?? '?'}</span>
              <span className="text-muted-foreground">
                {read
                  ? formatReadAt(m.read_at!)
                  : t('read_receipts.pending', 'Pendent')}
              </span>
            </li>
          )
        })}
      </ul>
    </div>
  )
}
