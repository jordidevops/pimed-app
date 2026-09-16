import { Navigate, Outlet, useLocation } from 'react-router-dom'
import { useIsFieldService } from '@/hooks/useSectorLabel'
import { useTenant } from '@/contexts/TenantContext'

export function FieldServiceLayout() {
  const location = useLocation()
  const { tenantsLoading } = useTenant()
  const isFieldService = useIsFieldService()

  if (tenantsLoading) {
    return (
      <div className="flex h-64 items-center justify-center" aria-busy="true">
        <div className="h-8 w-8 animate-spin rounded-full border-b-2 border-primary" />
      </div>
    )
  }

  if (!isFieldService) {
    return <Navigate to="/dashboard" replace />
  }

  if (location.pathname === '/field' || location.pathname === '/field/') {
    return <Navigate to="/field/today" replace />
  }

  return <Outlet />
}
