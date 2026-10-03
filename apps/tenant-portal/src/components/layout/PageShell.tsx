import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from 'react'
import { cn } from '@/lib/utils'
import { useIsLargeScreen } from '@/hooks/useIsLargeScreen'
import { Sheet, SheetContent, SheetTitle } from '@/components/ui/sheet'

export type PageShellProps = {
  title?: ReactNode
  subtitle?: ReactNode
  icon?: ReactNode
  actions?: ReactNode
  tabs?: ReactNode
  /**
   * Filters / view controls — scrolls with the list column (not sticky).
   * Sticky chrome is title + tabs only.
   */
  toolbar?: ReactNode
  /** Right-hand inspector (desktop split; mobile Sheet). */
  inspector?: ReactNode
  inspectorOpen?: boolean
  onInspectorClose?: () => void
  children: ReactNode
  className?: string
  /** Skip list max-width (rare). Header is always full width. */
  flush?: boolean
  /** Compact header (detail). */
  dense?: boolean
  /**
   * Content-only shell for nested hub routes that already render title/tabs
   * in a parent PageShell.
   */
  bare?: boolean
}

const INSPECTOR_WIDTH_PX = 360
const INSPECTOR_WIDTH_CLASS = 'w-[22.5rem]'

type InspectorGeom = {
  top: number
  right: number
  height: number
  scrimLeft: number
  scrimWidth: number
  overlaying: boolean
}

export function PageShell({
  title,
  subtitle,
  icon,
  actions,
  tabs,
  toolbar,
  inspector,
  inspectorOpen = Boolean(inspector),
  onInspectorClose,
  children,
  className,
  flush = false,
  dense = false,
  bare = false,
}: PageShellProps) {
  const isLarge = useIsLargeScreen()
  const showSplit = Boolean(inspector) && inspectorOpen && isLarge
  const showMobileSheet = Boolean(inspector) && inspectorOpen && !isLarge
  const showChrome = !bare && (Boolean(title) || Boolean(tabs) || Boolean(actions))
  const chromeRef = useRef<HTMLDivElement>(null)
  const listRef = useRef<HTMLDivElement>(null)
  const [geom, setGeom] = useState<InspectorGeom | null>(null)

  useEffect(() => {
    if (bare || !showChrome) return
    const el = chromeRef.current
    if (!el) return

    const publish = () => {
      document.documentElement.style.setProperty(
        '--app-sticky-chrome',
        `${el.getBoundingClientRect().height}px`,
      )
    }
    publish()
    const ro = new ResizeObserver(publish)
    ro.observe(el)
    return () => {
      ro.disconnect()
      document.documentElement.style.removeProperty('--app-sticky-chrome')
    }
  }, [bare, showChrome, title, subtitle, tabs, actions, dense])

  useLayoutEffect(() => {
    if (!showSplit) {
      setGeom(null)
      return
    }
    const listEl = listRef.current
    if (!listEl) return

    const measure = () => {
      const mainEl = listEl.closest('main')
      const mainRect = (mainEl ?? document.documentElement).getBoundingClientRect()
      const listRect = listEl.getBoundingClientRect()
      const chromeRaw = getComputedStyle(document.documentElement).getPropertyValue(
        '--app-sticky-chrome',
      )
      const chrome = Number.parseFloat(chromeRaw) || 0
      const top = Math.round(mainRect.top + chrome)
      const height = Math.max(160, Math.round(mainRect.bottom - top))
      const right = Math.max(0, Math.round(window.innerWidth - mainRect.right))
      const overlaying = listRect.right > mainRect.right - INSPECTOR_WIDTH_PX + 0.5
      setGeom({
        top,
        right,
        height,
        scrimLeft: Math.round(mainRect.left),
        scrimWidth: Math.max(0, Math.round(mainRect.width - INSPECTOR_WIDTH_PX)),
        overlaying,
      })
    }

    measure()
    const ro = new ResizeObserver(measure)
    ro.observe(listEl)
    const mainEl = listEl.closest('main')
    if (mainEl) ro.observe(mainEl)
    window.addEventListener('resize', measure)
    return () => {
      ro.disconnect()
      window.removeEventListener('resize', measure)
    }
  }, [showSplit, inspectorOpen])

  useEffect(() => {
    if (!showSplit) return
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== 'Escape') return
      event.preventDefault()
      onInspectorClose?.()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [showSplit, onInspectorClose])

  return (
    <div className={cn('flex min-h-full w-full max-w-none flex-col', className)}>
      {showChrome ? (
        <div
          ref={chromeRef}
          className={cn(
            'sticky top-0 z-20 w-full bg-background/95 px-4 pb-0 pt-5 backdrop-blur-md supports-[backdrop-filter]:bg-background/85 sm:px-6 sm:pt-6',
            !tabs && 'border-b border-border/80',
          )}
        >
          <div
            className={cn(
              'flex w-full shrink-0 flex-wrap items-start gap-3',
              tabs ? 'pb-3' : 'pb-4',
              dense ? 'gap-2' : 'gap-3',
            )}
          >
            {icon ? (
              <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl bg-primary/10 text-primary">
                {icon}
              </div>
            ) : null}
            <div className="min-w-0 flex-1">
              {title ? (
                <h1
                  className={cn(
                    'font-bold tracking-tight text-foreground',
                    dense ? 'text-xl' : 'text-2xl',
                  )}
                >
                  {title}
                </h1>
              ) : null}
              {subtitle ? (
                <p className="mt-0.5 text-sm text-muted-foreground">{subtitle}</p>
              ) : null}
            </div>
            {actions ? (
              <div className="flex shrink-0 flex-wrap items-center gap-2">{actions}</div>
            ) : null}
          </div>

          {tabs ? <div className="w-full shrink-0">{tabs}</div> : null}
        </div>
      ) : null}

      <div
        className={cn(
          'min-h-0 w-full flex-1',
          !bare && 'px-4 pb-6 pt-4 sm:px-6',
          bare && 'pt-3',
        )}
      >
        <div
          ref={listRef}
          className={cn('min-w-0 space-y-3', flush ? 'w-full' : 'app-list-column')}
        >
          {toolbar ? <div className="space-y-2">{toolbar}</div> : null}
          {children}
        </div>
      </div>

      {showSplit && geom ? (
        <>
          {geom.overlaying ? (
            <button
              type="button"
              aria-label="Close inspector"
              className="fixed z-30 hidden bg-foreground/20 lg:block"
              style={{
                top: geom.top,
                left: geom.scrimLeft,
                width: geom.scrimWidth,
                height: geom.height,
              }}
              onClick={() => onInspectorClose?.()}
            />
          ) : null}
          <aside
            className={cn(
              INSPECTOR_WIDTH_CLASS,
              'fixed z-40 hidden overflow-hidden border-l border-border bg-background shadow-lg lg:flex lg:flex-col',
              !geom.overlaying && 'shadow-none',
            )}
            style={{
              top: geom.top,
              right: geom.right,
              height: geom.height,
            }}
          >
            <div className="flex min-h-0 flex-1 flex-col overflow-hidden">{inspector}</div>
          </aside>
        </>
      ) : null}

      <Sheet
        open={showMobileSheet}
        onOpenChange={(open) => {
          if (!open) onInspectorClose?.()
        }}
      >
        <SheetContent
          side="right"
          className="flex w-full flex-col gap-0 border-l p-0 sm:max-w-md"
          showClose={false}
        >
          <SheetTitle className="sr-only">Inspector</SheetTitle>
          <div className="flex min-h-0 flex-1 flex-col overflow-hidden bg-background">
            {inspector}
          </div>
        </SheetContent>
      </Sheet>
    </div>
  )
}
