import { cn } from '@/lib/utils'

export interface FilterPillOption {
  id: string
  label: string
  count: number
}

export function FilterPillRow({
  label,
  value,
  onChange,
  allLabel,
  options,
  testId,
}: {
  label: string
  value: string
  onChange: (id: string) => void
  allLabel: string
  options: FilterPillOption[]
  testId?: string
}) {
  if (options.length === 0) return null

  return (
    <div className="min-w-0 space-y-1.5" data-testid={testId}>
      <p className="text-xs font-medium text-muted-foreground">{label}</p>
      <div
        className={cn(
          'flex flex-nowrap gap-1.5 overflow-x-auto overscroll-x-contain pb-0.5',
          '[scrollbar-width:none] [-ms-overflow-style:none] [&::-webkit-scrollbar]:hidden',
        )}
        role="group"
        aria-label={label}
      >
        <button
          type="button"
          onClick={() => onChange('')}
          aria-pressed={value === ''}
          className={cn(
            'shrink-0 rounded-full border px-3 py-1 text-xs font-medium transition-colors',
            value === ''
              ? 'border-primary bg-primary text-primary-foreground shadow-sm'
              : 'border-border bg-background text-muted-foreground hover:border-foreground/20 hover:text-foreground',
          )}
        >
          {allLabel}
        </button>
        {options.map((opt) => {
          const selected = value === opt.id
          return (
            <button
              key={opt.id}
              type="button"
              onClick={() => onChange(opt.id)}
              aria-pressed={selected}
              className={cn(
                'inline-flex shrink-0 items-center gap-1.5 rounded-full border px-3 py-1 text-xs font-medium transition-colors',
                selected
                  ? 'border-primary bg-primary text-primary-foreground shadow-sm'
                  : 'border-border bg-background text-muted-foreground hover:border-foreground/20 hover:text-foreground',
              )}
            >
              <span className="max-w-[10rem] truncate">{opt.label}</span>
              <span
                className={cn(
                  'rounded-full px-1.5 py-px text-[10px] font-semibold tabular-nums',
                  selected
                    ? 'bg-primary-foreground/20 text-primary-foreground'
                    : 'bg-muted text-muted-foreground',
                )}
              >
                {opt.count}
              </span>
            </button>
          )
        })}
      </div>
    </div>
  )
}
