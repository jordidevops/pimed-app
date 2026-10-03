import type { ReactNode } from 'react'
import { cn } from '@/lib/utils'
import { ScrollableTabBar } from '@/components/ui/scrollable-tab-bar'

export type UnderlineTabItem = {
  key: string
  label: ReactNode
  onSelect?: () => void
  href?: string
  end?: boolean
}

type UnderlineTabsProps = {
  activeKey: string
  items?: UnderlineTabItem[]
  children?: ReactNode
  'aria-label'?: string
  className?: string
}

/**
 * App-wide tab chrome: underline style matching Contacts
 * (ScrollableTabBar + border-b-2 active indicator).
 */
export function UnderlineTabs({
  activeKey,
  items,
  children,
  'aria-label': ariaLabel,
  className,
}: UnderlineTabsProps) {
  return (
    <ScrollableTabBar
      activeKey={activeKey}
      aria-label={ariaLabel}
      className={cn('border-b border-border', className)}
    >
      {children ??
        items?.map((item) => (
          <button
            key={item.key}
            type="button"
            data-tab-key={item.key}
            onClick={item.onSelect}
            className={cn(
              '-mb-px whitespace-nowrap border-b-2 px-4 py-2 text-sm font-medium transition-colors',
              activeKey === item.key
                ? 'border-primary text-primary'
                : 'border-transparent text-muted-foreground hover:text-foreground',
            )}
          >
            {item.label}
          </button>
        ))}
    </ScrollableTabBar>
  )
}

export function underlineTabClass(active: boolean): string {
  return cn(
    '-mb-px whitespace-nowrap border-b-2 px-4 py-2 text-sm font-medium transition-colors',
    active
      ? 'border-primary text-primary'
      : 'border-transparent text-muted-foreground hover:text-foreground',
  )
}
