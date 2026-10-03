import type { ReactNode } from 'react'
import { cn } from '@/lib/utils'

type SalesDocCardProps = {
  title: ReactNode
  subtitle?: ReactNode
  meta?: ReactNode
  amount?: ReactNode
  amountHint?: ReactNode
  badges?: ReactNode
  /** Left accent: billing/collection semantic. */
  tone?: 'neutral' | 'pending' | 'partial' | 'paid' | 'danger' | 'draft'
  active?: boolean
  onClick?: () => void
  className?: string
  footer?: ReactNode
}

const toneBar: Record<NonNullable<SalesDocCardProps['tone']>, string> = {
  neutral: 'bg-border',
  pending: 'bg-amber-500',
  partial: 'bg-sky-500',
  paid: 'bg-emerald-500',
  danger: 'bg-destructive',
  draft: 'bg-muted-foreground/40',
}

const toneWash: Record<NonNullable<SalesDocCardProps['tone']>, string> = {
  neutral: 'from-muted/40 to-card',
  pending: 'from-amber-500/10 to-card',
  partial: 'from-sky-500/10 to-card',
  paid: 'from-emerald-500/10 to-card',
  danger: 'from-destructive/10 to-card',
  draft: 'from-muted/50 to-card',
}

export function SalesDocCard({
  title,
  subtitle,
  meta,
  amount,
  amountHint,
  badges,
  tone = 'neutral',
  active = false,
  onClick,
  className,
  footer,
}: SalesDocCardProps) {
  const classNames = cn(
    'group relative w-full overflow-hidden rounded-2xl border text-left shadow-sm transition-all',
    'bg-gradient-to-br',
    toneWash[tone],
    active
      ? 'border-primary ring-2 ring-primary/20 shadow-md'
      : 'border-border/80 hover:border-primary/35 hover:shadow-md',
    onClick && 'cursor-pointer',
    className,
  )

  const body = (
    <>
      <span className={cn('absolute inset-y-0 left-0 w-1', toneBar[tone])} aria-hidden />
      <div className="space-y-3 p-4 pl-5">
        <div className="flex items-start justify-between gap-3">
          <div className="min-w-0 space-y-1">
            <p className="truncate text-base font-semibold tracking-tight text-foreground">
              {title}
            </p>
            {subtitle ? (
              <p className="truncate text-sm text-muted-foreground">{subtitle}</p>
            ) : null}
          </div>
          {amount != null ? (
            <div className="shrink-0 text-right">
              <p className="text-lg font-semibold tabular-nums tracking-tight text-foreground">
                {amount}
              </p>
              {amountHint ? (
                <p className="text-xs text-muted-foreground">{amountHint}</p>
              ) : null}
            </div>
          ) : null}
        </div>
        {badges ? <div className="flex flex-wrap gap-1.5">{badges}</div> : null}
        {meta ? <div className="text-xs text-muted-foreground">{meta}</div> : null}
        {footer ? <div className="pt-0.5">{footer}</div> : null}
      </div>
    </>
  )

  if (onClick) {
    return (
      <button type="button" onClick={onClick} className={classNames}>
        {body}
      </button>
    )
  }

  return <div className={classNames}>{body}</div>
}
