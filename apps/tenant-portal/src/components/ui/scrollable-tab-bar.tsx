import { useCallback, useEffect, useRef, useState } from 'react'
import { ChevronLeft, ChevronRight } from 'lucide-react'
import { cn } from '@/lib/utils'

/**
 * Strip horitzontal amb overflow elegant: scrollbar oculta, fades laterals i chevrons.
 * Els fades/chevrons només apareixen quan hi ha overflow (també amb pocs ítems en viewport estret).
 */
export function ScrollableTabBar({
  children,
  activeKey,
  className,
  scrollerClassName,
  'aria-label': ariaLabel,
  role = 'tablist',
  mapVerticalWheel = true,
  edgeAlign = 'center',
  scrollStep,
}: {
  children: React.ReactNode
  /** Quan canvia, fa scroll a l'element [data-tab-key=activeKey] */
  activeKey?: string
  className?: string
  scrollerClassName?: string
  'aria-label'?: string
  /** Passa `null` si el fill ja defineix el role (p.ex. Radix TabsList). */
  role?: React.AriaRole | null
  /**
   * Si true (tabs), la roda vertical desplaça horitzontalment.
   * Desactiva-ho en taulers (Kanban) perquè les columnes puguin fer scroll vertical.
   */
  mapVerticalWheel?: boolean
  /** On col·locar els chevrons dins el fade: centre (tabs) o a dalt (taulers alts). */
  edgeAlign?: 'center' | 'start'
  /** Pas de scroll en px; per defecte ~60% de l'ample visible. */
  scrollStep?: number
}) {
  const scrollerRef = useRef<HTMLDivElement>(null)
  const [canLeft, setCanLeft] = useState(false)
  const [canRight, setCanRight] = useState(false)

  const updateOverflow = useCallback(() => {
    const el = scrollerRef.current
    if (!el) return
    const max = el.scrollWidth - el.clientWidth
    setCanLeft(el.scrollLeft > 2)
    setCanRight(max > 2 && el.scrollLeft < max - 2)
  }, [])

  useEffect(() => {
    const el = scrollerRef.current
    if (!el) return
    updateOverflow()
    const ro = new ResizeObserver(() => updateOverflow())
    ro.observe(el)
    // Observa fills (tabs que apareixen/desapareixen)
    for (const child of Array.from(el.children)) {
      if (child instanceof Element) ro.observe(child)
    }
    el.addEventListener('scroll', updateOverflow, { passive: true })
    window.addEventListener('resize', updateOverflow)

    const onWheel = (e: WheelEvent) => {
      if (!mapVerticalWheel) return
      if (el.scrollWidth <= el.clientWidth) return
      if (Math.abs(e.deltaY) <= Math.abs(e.deltaX)) return
      el.scrollLeft += e.deltaY
      e.preventDefault()
    }
    el.addEventListener('wheel', onWheel, { passive: false })

    return () => {
      ro.disconnect()
      el.removeEventListener('scroll', updateOverflow)
      el.removeEventListener('wheel', onWheel)
      window.removeEventListener('resize', updateOverflow)
    }
  }, [updateOverflow, children, mapVerticalWheel])

  useEffect(() => {
    const el = scrollerRef.current
    if (!el) return

    const target = activeKey
      ? el.querySelector<HTMLElement>(`[data-tab-key="${CSS.escape(activeKey)}"]`)
      : el.querySelector<HTMLElement>('[data-state="active"], [aria-selected="true"]')

    if (!target) return

    // Only scroll this horizontal strip — never scrollIntoView (that also
    // scrolls ancestor overflow containers like AppLayout <main>).
    const targetLeft = target.offsetLeft
    const targetRight = targetLeft + target.offsetWidth
    const viewLeft = el.scrollLeft
    const viewRight = viewLeft + el.clientWidth
    let nextLeft = viewLeft
    if (targetLeft < viewLeft) nextLeft = targetLeft
    else if (targetRight > viewRight) nextLeft = targetRight - el.clientWidth
    if (Math.abs(nextLeft - viewLeft) > 1) {
      el.scrollTo({ left: nextLeft, behavior: 'smooth' })
    }

    const t = window.setTimeout(updateOverflow, 320)
    return () => window.clearTimeout(t)
  }, [activeKey, updateOverflow, children])

  function scrollByDir(dir: -1 | 1) {
    const el = scrollerRef.current
    if (!el) return
    const firstChild = el.firstElementChild as HTMLElement | null
    const childStep = firstChild ? firstChild.offsetWidth + 12 : 0
    const amount =
      scrollStep ??
      Math.max(160, childStep || Math.floor(el.clientWidth * 0.6))
    el.scrollBy({ left: dir * amount, behavior: 'smooth' })
  }

  const edgeAlignClass = edgeAlign === 'start' ? 'items-start pt-2.5' : 'items-center'

  return (
    <div className={cn('relative min-w-0 w-full', className)}>
      {canLeft ? (
        <div
          className={cn(
            'pointer-events-none absolute inset-y-0 left-0 z-10 flex w-12 bg-gradient-to-r from-background via-background/90 to-transparent',
            edgeAlignClass,
          )}
        >
          <button
            type="button"
            tabIndex={-1}
            className="pointer-events-auto ml-0.5 flex h-8 w-8 items-center justify-center rounded-full border border-border bg-background/95 text-muted-foreground shadow-sm backdrop-blur-sm transition-colors hover:bg-background hover:text-foreground"
            onClick={() => scrollByDir(-1)}
            aria-label="Scroll left"
          >
            <ChevronLeft className="h-4 w-4" />
          </button>
        </div>
      ) : null}

      {canRight ? (
        <div
          className={cn(
            'pointer-events-none absolute inset-y-0 right-0 z-10 flex w-12 justify-end bg-gradient-to-l from-background via-background/90 to-transparent',
            edgeAlignClass,
          )}
        >
          <button
            type="button"
            tabIndex={-1}
            className="pointer-events-auto mr-0.5 flex h-8 w-8 items-center justify-center rounded-full border border-border bg-background/95 text-muted-foreground shadow-sm backdrop-blur-sm transition-colors hover:bg-background hover:text-foreground"
            onClick={() => scrollByDir(1)}
            aria-label="Scroll right"
          >
            <ChevronRight className="h-4 w-4" />
          </button>
        </div>
      ) : null}

      <div
        ref={scrollerRef}
        role={role === null ? undefined : role}
        aria-label={ariaLabel}
        className={cn(
          'flex min-w-0 flex-nowrap gap-x-1 overflow-x-auto overscroll-x-contain',
          '[scrollbar-width:none] [-ms-overflow-style:none] [&::-webkit-scrollbar]:hidden',
          scrollerClassName,
        )}
      >
        {children}
      </div>
    </div>
  )
}
