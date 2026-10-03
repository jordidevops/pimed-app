import type { ReactNode } from 'react'
import { X } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { cn } from '@/lib/utils'

export type InspectorField = {
  label: ReactNode
  value: ReactNode
}

export type InspectorSheetProps = {
  title: ReactNode
  subtitle?: ReactNode
  badges?: ReactNode
  fields?: InspectorField[]
  children?: ReactNode
  footer?: ReactNode
  onClose?: () => void
  className?: string
  /** Hide chrome header when parent Sheet already shows title (mobile). */
  hideHeader?: boolean
}

/**
 * Inspector chrome for a full-height side panel.
 * Header and footer stay put; only the body scrolls.
 */
export function InspectorSheet({
  title,
  subtitle,
  badges,
  fields,
  children,
  footer,
  onClose,
  className,
  hideHeader = false,
}: InspectorSheetProps) {
  return (
    <div
      className={cn(
        'flex h-full max-h-full min-h-0 w-full flex-col overflow-hidden bg-background',
        className,
      )}
    >
      {!hideHeader ? (
        <div className="flex shrink-0 items-start justify-between gap-2 border-b border-border px-4 py-3">
          <div className="min-w-0 space-y-1">
            <h2 className="truncate text-base font-semibold text-foreground">{title}</h2>
            {subtitle ? (
              <p className="truncate text-sm text-muted-foreground">{subtitle}</p>
            ) : null}
            {badges ? <div className="flex flex-wrap gap-1.5 pt-1">{badges}</div> : null}
          </div>
          {onClose ? (
            <Button
              type="button"
              size="icon"
              variant="ghost"
              className="h-8 w-8 shrink-0"
              onClick={onClose}
            >
              <X className="h-4 w-4" />
              <span className="sr-only">Close</span>
            </Button>
          ) : null}
        </div>
      ) : null}

      <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain px-4 py-3">
        <div className="space-y-3">
          {fields && fields.length > 0 ? (
            <dl className="space-y-2">
              {fields.map((field, index) => (
                <div
                  key={index}
                  className="grid grid-cols-[6.5rem_minmax(0,1fr)] gap-x-3 gap-y-0.5 text-sm"
                >
                  <dt className="text-muted-foreground">{field.label}</dt>
                  <dd className="min-w-0 font-medium text-foreground">{field.value}</dd>
                </div>
              ))}
            </dl>
          ) : null}
          {children}
        </div>
      </div>

      {footer ? (
        <div className="flex shrink-0 flex-wrap gap-2 border-t border-border bg-background px-4 py-3">
          {footer}
        </div>
      ) : null}
    </div>
  )
}
