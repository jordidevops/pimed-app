import { useTranslation } from 'react-i18next'
import { useAuth } from '@/contexts/AuthContext'
import { useTenant } from '@/contexts/TenantContext'
import { useEffectiveSettings } from '@/hooks/useSettings'
import { AttendanceMonthlyCloseSettingsSection } from '@/features/attendance/components/settings/AttendanceMonthlyCloseSettingsSection'
import { AttendanceStationPunchPolicySection } from '@/features/attendance/components/settings/AttendanceStationPunchPolicySection'
import { AttendanceGeoSettingsSection } from '@/features/attendance/components/settings/AttendanceGeoSettingsSection'
import { AttendancePunchDiscrepancySettingsSection } from '@/features/attendance/components/settings/AttendancePunchDiscrepancySettingsSection'
import { AttendancePunchReminderSettingsSection } from '@/features/attendance/components/settings/AttendancePunchReminderSettingsSection'
import { AttendanceOvertimeSettingsSection } from '@/features/attendance/components/settings/AttendanceOvertimeSettingsSection'
import { AttendanceEffectiveTimeSettingsSection } from '@/features/attendance/components/settings/AttendanceEffectiveTimeSettingsSection'
import { AttendancePayrollExportProfilesSection } from '@/features/attendance/components/settings/AttendancePayrollExportProfilesSection'
import { AttendanceStatutoryLimitsSection } from '@/features/attendance/components/settings/AttendanceStatutoryLimitsSection'
import { AttendanceLaborRulesSettingsSection } from '@/features/attendance/components/settings/AttendanceLaborRulesSettingsSection'
import { AttendanceAnomalyAutomationsSection } from '@/features/attendance/components/settings/AttendanceAnomalyAutomationsSection'
import { AttendanceProtocolSettingsSection } from '@/features/attendance/components/settings/AttendanceProtocolSettingsSection'
import { AttendanceAbsenceTypesSettingsSection } from '@/features/attendance/components/settings/AttendanceAbsenceTypesSettingsSection'
import { AttendanceRetentionSettingsSection } from '@/features/attendance/components/settings/AttendanceRetentionSettingsSection'
import { AttendanceInspectionAccessSection } from '@/features/attendance/components/settings/AttendanceInspectionAccessSection'

export function AttendanceControlPage() {
  const { t } = useTranslation('settings')
  const { user } = useAuth()
  const { activeTenant, activeRole } = useTenant()

  const canManage = activeRole === 'owner' || activeRole === 'manager'
  const tenantId = activeTenant?.id ?? null

  const { data: effective = {}, isLoading } = useEffectiveSettings(
    { tenantId, siteId: null, userId: user?.id },
    { enabled: !!tenantId },
  )

  if (!activeTenant) return null

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-lg font-semibold text-foreground">
          {t('tabs.attendance_control', 'Control horari')}
        </h2>
        <p className="mt-0.5 text-sm text-muted-foreground">
          {t(
            'attendance_control.page_description',
            'Configuració del fitxatge, geolocalització, incidències i tancament mensual per a nòmina.',
          )}
        </p>
      </div>

      {isLoading ? (
        <div className="rounded-2xl border p-6 animate-pulse space-y-3">
          <div className="h-4 bg-muted rounded w-1/3" />
          <div className="h-4 bg-muted rounded w-1/2" />
          <div className="h-4 bg-muted rounded w-2/5" />
        </div>
      ) : (
        <>
          <AttendanceMonthlyCloseSettingsSection effective={effective} canManage={canManage} />
          <AttendanceStationPunchPolicySection effective={effective} canManage={canManage} />
          <AttendanceGeoSettingsSection effective={effective} canManage={canManage} />
          <AttendancePunchDiscrepancySettingsSection effective={effective} canManage={canManage} />
          <AttendancePunchReminderSettingsSection effective={effective} canManage={canManage} />
          <AttendanceOvertimeSettingsSection effective={effective} canManage={canManage} />
          <AttendanceAbsenceTypesSettingsSection canManage={canManage} />
          <AttendanceEffectiveTimeSettingsSection effective={effective} canManage={canManage} />
          <AttendanceStatutoryLimitsSection effective={effective} canManage={canManage} />
          <AttendanceLaborRulesSettingsSection canManage={canManage} />
          <AttendanceAnomalyAutomationsSection effective={effective} canManage={canManage} />
          <AttendanceProtocolSettingsSection
            tenantId={tenantId}
            effective={effective}
            canManage={canManage}
          />
          <AttendancePayrollExportProfilesSection canManage={canManage} />
          <AttendanceInspectionAccessSection tenantId={tenantId} canManage={canManage} />
          <AttendanceRetentionSettingsSection effective={effective} canManage={canManage} />
        </>
      )}
    </div>
  )
}
