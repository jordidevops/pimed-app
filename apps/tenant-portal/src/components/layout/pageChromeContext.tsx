import {
  createContext,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from 'react'

type PageChromeContextValue = {
  setToolbar: (node: ReactNode | null) => void
  setActions: (node: ReactNode | null) => void
}

const PageChromeContext = createContext<PageChromeContextValue | null>(null)

export function PageChromeProvider({
  children,
  onToolbar,
  onActions,
}: {
  children: ReactNode
  onToolbar: (node: ReactNode | null) => void
  onActions?: (node: ReactNode | null) => void
}) {
  const value = useMemo(
    () => ({
      setToolbar: onToolbar,
      setActions: onActions ?? (() => undefined),
    }),
    [onToolbar, onActions],
  )
  return <PageChromeContext.Provider value={value}>{children}</PageChromeContext.Provider>
}

/** Registers toolbar into parent PageShell sticky chrome. Returns true when hosted. */
export function usePageChromeToolbar(toolbar: ReactNode | null | undefined): boolean {
  const ctx = useContext(PageChromeContext)
  useEffect(() => {
    if (!ctx) return
    ctx.setToolbar(toolbar ?? null)
    return () => ctx.setToolbar(null)
  }, [ctx, toolbar])
  return Boolean(ctx)
}

/** Registers header actions into parent PageShell. Returns true when hosted. */
export function usePageChromeActions(actions: ReactNode | null | undefined): boolean {
  const ctx = useContext(PageChromeContext)
  useEffect(() => {
    if (!ctx) return
    ctx.setActions(actions ?? null)
    return () => ctx.setActions(null)
  }, [ctx, actions])
  return Boolean(ctx)
}

export function usePageChromeHostState() {
  const [toolbar, setToolbar] = useState<ReactNode | null>(null)
  const [actions, setActions] = useState<ReactNode | null>(null)
  return { toolbar, setToolbar, actions, setActions }
}
