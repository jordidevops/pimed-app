import { useEffect, useState } from 'react'

export type ListDensity = 'compact' | 'comfortable'

const PREFIX = 'pimed.listDensity.'

function readStored(pageKey: string, fallback: ListDensity): ListDensity {
  try {
    const raw = localStorage.getItem(`${PREFIX}${pageKey}`)
    if (raw === 'compact' || raw === 'comfortable') return raw
  } catch {
    /* ignore */
  }
  return fallback
}

export function useListDensity(
  pageKey: string,
  defaultDensity: ListDensity = 'compact',
): {
  density: ListDensity
  setDensity: (density: ListDensity) => void
} {
  const [density, setDensity] = useState<ListDensity>(() => readStored(pageKey, defaultDensity))

  useEffect(() => {
    setDensity(readStored(pageKey, defaultDensity))
  }, [pageKey, defaultDensity])

  useEffect(() => {
    try {
      localStorage.setItem(`${PREFIX}${pageKey}`, density)
    } catch {
      /* ignore */
    }
  }, [pageKey, density])

  return { density, setDensity }
}
