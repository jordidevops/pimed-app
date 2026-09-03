import { cn } from '@/lib/utils'
import { Button } from '@/components/ui/button'

export interface PillOption<T extends string> {
  value: T
  label: string
}

interface PillToggleGroupProps<T extends string> {
  value: T
  options: PillOption<T>[]
  onChange: (value: T) => void
  className?: string
  size?: 'sm' | 'default'
}

export function PillToggleGroup<T extends string>({
  value,
  options,
  onChange,
  className,
  size = 'sm',
}: PillToggleGroupProps<T>) {
  return (
    <div className={cn('inline-flex flex-wrap gap-1 rounded-lg border bg-muted/40 p-1', className)}>
      {options.map((opt) => (
        <Button
          key={opt.value}
          type="button"
          size={size}
          variant={value === opt.value ? 'default' : 'ghost'}
          className={cn(
            'h-7 px-2.5 text-xs',
            value !== opt.value && 'text-muted-foreground hover:text-foreground',
          )}
          onClick={() => onChange(opt.value)}
        >
          {opt.label}
        </Button>
      ))}
    </div>
  )
}
