import { Navigate } from 'react-router-dom'

/** Redirigeix al hub d'empleats (sub-tab Contingut). */
export function EmployeeContentListPage() {
  return <Navigate to="/employees?tab=portal_hub&section=content" replace />
}
