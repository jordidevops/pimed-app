import { Navigate, useLocation } from 'react-router-dom'
import { ATTENDANCE_MGMT_BASE, LEGACY_CONTROL_HORARI_SEGMENTS } from '../attendanceMgmtRoutes'

/** Redirects old Catalan /control-horari/* URLs to /attendance-mgmt/* */
export function LegacyControlHorariRedirect() {
  const location = useLocation()
  const suffix = location.pathname.replace(/^\/control-horari\/?/, '') || 'tauler'
  const mapped = LEGACY_CONTROL_HORARI_SEGMENTS[suffix] ?? 'dashboard'
  return (
    <Navigate
      to={`${ATTENDANCE_MGMT_BASE}/${mapped}${location.search}${location.hash}`}
      replace
    />
  )
}
