import { useEffect, useState } from 'react'

export type ListViewMode = 'table' | 'cards'

const PREFIX = 'pimed.listView.'

function readStored(pageKey: string, fallback: ListViewMode): ListViewMode {
  try {
    const raw = localStorage.getItem(`${PREFIX}${pageKey}`)
    if (raw === 'table' || raw === 'cards') return raw
  } catch {
    /* ignore */
  }
  return fallback
}

/**
 * Persisted list presentation. On viewports below `md`, cards are forced for
 * display without overwriting the desktop preference in localStorage.
 */
export function useListViewMode(
  pageKey: string,
  defaultMode: ListViewMode = 'table',
): {
  mode: ListViewMode
  setMode: (mode: ListViewMode) => void
  /** Effective mode (cards under md). */
  effectiveMode: ListViewMode
  isMobileForced: boolean
} {
  const [mode, setModeState] = useState<ListViewMode>(() => readStored(pageKey, defaultMode))
  const [isNarrow, setIsNarrow] = useState(() =>
    typeof window !== 'undefined' ? !window.matchMedia('(min-width: 768px)').matches : false,
  )

  useEffect(() => {
    setModeState(readStored(pageKey, defaultMode))
  }, [pageKey, defaultMode])

  useEffect(() => {
    const media = window.matchMedia('(min-width: 768px)')
    const onChange = () => setIsNarrow(!media.matches)
    onChange()
    media.addEventListener('change', onChange)
    return () => media.removeEventListener('change', onChange)
  }, [])

  useEffect(() => {
    try {
      localStorage.setItem(`${PREFIX}${pageKey}`, mode)
    } catch {
      /* ignore */
    }
  }, [pageKey, mode])

  return {
    mode,
    setMode: setModeState,
    effectiveMode: isNarrow ? 'cards' : mode,
    isMobileForced: isNarrow,
  }
}
