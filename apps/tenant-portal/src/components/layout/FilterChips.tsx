import { X } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { cn } from '@/lib/utils'

export type FilterChip = {
  key: string
  label: string
  onRemove: () => void
}

type FilterChipsProps = {
  chips: FilterChip[]
  className?: string
  clearAllLabel?: string
  onClearAll?: () => void
}

export function FilterChips({ chips, className, clearAllLabel, onClearAll }: FilterChipsProps) {
  if (chips.length === 0) return null

  return (
    <div className={cn('flex flex-wrap items-center gap-1.5', className)}>
      {chips.map((chip) => (
        <button
          key={chip.key}
          type="button"
          onClick={chip.onRemove}
          className="inline-flex items-center gap-1 rounded-md border border-border bg-muted/50 px-2 py-0.5 text-xs text-foreground hover:bg-muted"
        >
          <span>{chip.label}</span>
          <X className="h-3 w-3 text-muted-foreground" aria-hidden />
        </button>
      ))}
      {onClearAll && chips.length > 1 ? (
        <Button type="button" variant="ghost" size="sm" className="h-6 px-2 text-xs" onClick={onClearAll}>
          {clearAllLabel ?? 'Clear'}
        </Button>
      ) : null}
    </div>
  )
}
