import { useEffect, useRef } from 'react'
import { useLocation } from 'react-router-dom'
import { markOperationsDashboardSeen } from '../features/operations'

/**
 * Actualitza la marca de "darrer accés al tauler" quan l'usuari surt de /dashboard.
 * Evita cleanup a StrictMode remount (no usar unmount directe).
 */
export function useMarkOperationsDashboardVisit(
  userId: string | undefined,
  tenantId: string | undefined,
) {
  const { pathname } = useLocation()
  const wasOnDashboardRef = useRef(false)

  useEffect(() => {
    const onDashboard = pathname === '/dashboard' || pathname === '/dashboard/'

    if (wasOnDashboardRef.current && !onDashboard && userId && tenantId) {
      markOperationsDashboardSeen(userId, tenantId)
    }

    wasOnDashboardRef.current = onDashboard
  }, [pathname, userId, tenantId])
}
