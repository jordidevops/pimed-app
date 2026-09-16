import { useAuth } from '@/contexts/AuthContext'
import { useTenant } from '@/contexts/TenantContext'
import { useIsFieldService } from '@/hooks/useSectorLabel'
import { useEffectiveSettings } from '@/hooks/useSettings'
import { useIsLargeScreen } from '@/hooks/useIsLargeScreen'
import {
  DASHBOARD_PATH,
  FIELD_SERVICE_HOME_SETTING_KEY,
  FIELD_TODAY_PATH,
  isFieldServiceOfficeRole,
  parseFieldServiceHomePreference,
  resolveFieldServiceHomePath,
  type FieldServiceHomePath,
  type FieldServiceHomePreference,
} from '../utils/resolveFieldServiceHome'

export function useFieldServiceHome(): {
  path: FieldServiceHomePath
  preference: FieldServiceHomePreference
  canConfigure: boolean
  ready: boolean
} {
  const { user } = useAuth()
  const { activeTenant, activeRole, tenantsLoading } = useTenant()
  const isFieldService = useIsFieldService()
  const isLargeScreen = useIsLargeScreen()
  const canConfigure = isFieldService && isFieldServiceOfficeRole(activeRole)

  const settingsQuery = useEffectiveSettings(
    { tenantId: activeTenant?.id ?? null, userId: user?.id ?? null },
    { enabled: canConfigure && !!activeTenant?.id },
  )

  const preference = parseFieldServiceHomePreference(
    settingsQuery.data?.[FIELD_SERVICE_HOME_SETTING_KEY],
  )

  const path = resolveFieldServiceHomePath({
    isFieldService,
    role: activeRole,
    isLargeScreen,
    preference,
  })

  const ready =
    !tenantsLoading &&
    (!canConfigure || !activeTenant?.id || !settingsQuery.isLoading)

  return {
    path: isFieldService ? path : DASHBOARD_PATH,
    preference,
    canConfigure,
    ready,
  }
}

export { FIELD_TODAY_PATH, DASHBOARD_PATH, FIELD_SERVICE_HOME_SETTING_KEY }
