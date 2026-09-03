import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { FileText, Loader2 } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { useEffectiveSettings } from '@/hooks/useSettings'
import { parseProtocolSettings } from '../api/protocolSettings'
import { parseStatutoryLimits } from '../api/statutoryLimitsSettings'
import { publishAttendanceProtocol } from '../api/attendanceProtocolService'

interface AttendanceProtocolPublishButtonProps {
  employeeId: string
  employeeName: string
  employeeEmail?: string | null
  workProfile?: string | null
}

export function AttendanceProtocolPublishButton({
  employeeId,
  employeeName,
  employeeEmail,
  workProfile,
}: AttendanceProtocolPublishButtonProps) {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const { activeTenant } = useTenant()
  const { data: effective = {} } = useEffectiveSettings(
    { tenantId: activeTenant?.id ?? null, siteId: null },
    { enabled: !!activeTenant?.id },
  )
  const [loading, setLoading] = useState(false)

  async function handlePublish() {
    if (!activeTenant?.id) return
    setLoading(true)
    try {
      const protocolSettings = parseProtocolSettings(effective)
      const statutory = parseStatutoryLimits(effective)
      const result = await publishAttendanceProtocol({
        tenantId: activeTenant.id,
        tenantName: activeTenant.name ?? activeTenant.slug ?? 'Empresa',
        employeeId,
        employeeName,
        employeeEmail,
        workProfile: workProfile ?? 'fixed_site',
        jurisdictionCode: statutory.jurisdictionCode,
        protocolSettings,
      })
      toast({
        title: t('protocol.publish_success', 'Protocol publicat'),
        description: t(
          'protocol.publish_success_desc',
          'L\'empleat el veurà a la pestanya Documents del portal.',
        ),
      })
      if (result.signing?.submission_id) {
        toast({
          title: t('protocol.signing_started', 'Signatura iniciada'),
          description: t(
            'protocol.signing_started_desc',
            'S\'ha enviat la sol·licitud de signatura digital a l\'empleat.',
          ),
        })
      }
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('protocol.publish_error', 'No s\'ha pogut publicar'),
        description: err instanceof Error ? err.message : String(err),
      })
    } finally {
      setLoading(false)
    }
  }

  return (
    <Button type="button" variant="outline" size="sm" disabled={loading} onClick={() => void handlePublish()}>
      {loading ? (
        <Loader2 className="mr-1.5 h-4 w-4 animate-spin" />
      ) : (
        <FileText className="mr-1.5 h-4 w-4" />
      )}
      {t('protocol.publish_button', 'Publicar protocol horari')}
    </Button>
  )
}
