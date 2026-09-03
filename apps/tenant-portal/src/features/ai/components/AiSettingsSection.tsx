import { useState } from 'react'
import { ChevronDown } from 'lucide-react'
import { cn } from '@/lib/utils'

type Props = {
  title: string
  description?: string
  defaultOpen?: boolean
  children: React.ReactNode
}

export function AiSettingsSection({
  title,
  description,
  defaultOpen = true,
  children,
}: Props) {
  const [open, setOpen] = useState(defaultOpen)

  return (
    <div className="rounded-lg border">
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        className="flex w-full items-start gap-2 p-4 text-left hover:bg-muted/40 transition rounded-lg"
        aria-expanded={open}
      >
        <ChevronDown
          className={cn(
            'h-4 w-4 shrink-0 mt-0.5 text-muted-foreground transition-transform',
            open && 'rotate-180',
          )}
        />
        <div className="flex-1 min-w-0 space-y-0.5">
          <span className="text-sm font-medium text-foreground">{title}</span>
          {description && (
            <p className="text-xs text-muted-foreground font-normal">{description}</p>
          )}
        </div>
      </button>
      {open && <div className="px-4 pb-4 pt-4 space-y-4 border-t">{children}</div>}
    </div>
  )
}
