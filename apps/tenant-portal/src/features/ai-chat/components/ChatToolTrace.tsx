import { Wrench } from 'lucide-react'
import { useTranslation } from 'react-i18next'
import { cn } from '@/lib/utils'

export type ChatToolTraceEntry = {
  name: string
  ok: boolean
}

type ChatToolTraceProps = {
  trace: ChatToolTraceEntry[]
  className?: string
}

export function ChatToolTrace({ trace, className }: ChatToolTraceProps) {
  const { t } = useTranslation('chat')

  if (!trace.length) return null

  const labels = trace.map((entry) => {
    const status = entry.ok ? '✓' : '✗'
    return `${entry.name} ${status}`
  })

  return (
    <div
      className={cn(
        'max-w-3xl mx-auto px-4 pb-2 flex items-center gap-2 text-xs text-muted-foreground',
        className,
      )}
    >
      <Wrench className="h-3.5 w-3.5 shrink-0" aria-hidden />
      <span>
        {t('toolsUsed', 'Eines utilitzades: {{tools}}', { tools: labels.join(', ') })}
      </span>
    </div>
  )
}
