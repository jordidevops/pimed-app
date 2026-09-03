import { useState, useEffect } from 'react'

/**
 * Retorna l'estat de connectivitat del navegador en temps real.
 * Nota: `navigator.onLine` pot donar false positives (WIFI sense internet).
 * Per al spike és suficient; Fase 5 pot afegir probes HTTP.
 */
export function useOnlineStatus(): boolean {
  const [isOnline, setIsOnline] = useState(() => navigator.onLine)

  useEffect(() => {
    const onOnline = () => setIsOnline(true)
    const onOffline = () => setIsOnline(false)

    window.addEventListener('online', onOnline)
    window.addEventListener('offline', onOffline)

    return () => {
      window.removeEventListener('online', onOnline)
      window.removeEventListener('offline', onOffline)
    }
  }, [])

  return isOnline
}
