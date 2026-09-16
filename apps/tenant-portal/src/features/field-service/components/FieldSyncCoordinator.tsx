import { useTenant } from '@/contexts/TenantContext'
import { useIsFieldService } from '@/hooks/useSectorLabel'
import { useFieldDeviceSync } from '../hooks/useFieldDeviceSync'

/** One app-wide owner for all field-device drain loops. */
export function FieldSyncCoordinator() {
  const { activeTenant } = useTenant()
  const isFieldService = useIsFieldService()
  useFieldDeviceSync(isFieldService ? (activeTenant?.id ?? null) : null)
  return null
}
