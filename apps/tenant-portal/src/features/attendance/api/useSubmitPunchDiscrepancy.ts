import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { useToast } from '@/hooks/use-toast'
import { attendanceKeys } from './attendanceKeys'
import {
  submitPunchDiscrepancy,
  type SubmitPunchDiscrepancyParams,
} from './punchDiscrepancyService'

export function useSubmitPunchDiscrepancy() {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: (params: SubmitPunchDiscrepancyParams) => submitPunchDiscrepancy(params),
    onSuccess: (result, params) => {
      if (!result.success) {
        toast({
          variant: 'destructive',
          title: t('discrepancy.error', 'No s’ha pogut registrar la resposta'),
          description: result.error,
        })
        return
      }

      void queryClient.invalidateQueries({ queryKey: attendanceKeys.all })
      void queryClient.invalidateQueries({ queryKey: ['attendance', 'today-dashboard'] })

      if (params.resolution === 'confirmed_ok') {
        toast({ description: t('discrepancy.confirmed_ok_toast', 'Fitxatge confirmat') })
      } else if (params.resolution === 'strip_geo') {
        toast({ description: t('discrepancy.strip_geo_toast', 'Ubicació eliminada del fitxatge') })
      } else if (params.resolution === 'overtime_claimed') {
        toast({
          description: t(
            'discrepancy.overtime_toast',
            'Hores extra registrades per revisió del gestor',
          ),
        })
      } else if (params.resolution === 'scheduled_hours_claimed') {
        toast({
          description: t(
            'discrepancy.schedule_toast',
            'Sol·licitud de revisió registrada segons l’horari previst',
          ),
        })
      }
    },
    onError: (err: Error) => {
      toast({
        variant: 'destructive',
        title: t('discrepancy.error', 'No s’ha pogut registrar la resposta'),
        description: err.message,
      })
    },
  })
}
