import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { attendanceKeys } from './attendanceKeys'
import {
  getMyAbsences,
  getAllAbsences,
  requestAbsence,
  approveAbsence,
  listAbsenceTypeConfigs,
  registerIT,
  closeIT,
  cancelMyAbsence,
  revokeAbsence,
} from './shiftsService'

// ─── My Absences ──────────────────────────────────────────────────────────────

export function useMyAbsences(employeeId: string | null, from: string, to: string) {
  return useQuery({
    queryKey: attendanceKeys.myAbsences(employeeId ?? '', from, to),
    queryFn: () => getMyAbsences(employeeId!, from, to),
    enabled: !!employeeId && !!from && !!to,
  })
}

// ─── All Site Absences (manager) ──────────────────────────────────────────────

export function useSiteAbsences(from: string, to: string) {
  const { selectedSiteId } = useTenant()

  return useQuery({
    queryKey: attendanceKeys.siteAbsences(from, to),
    queryFn: () => getAllAbsences(from, to, selectedSiteId),
    enabled: !!from && !!to,
  })
}

// ─── Request Absence ──────────────────────────────────────────────────────────

export function useRequestAbsence() {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: requestAbsence,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: attendanceKeys.all })
      toast({ title: t('absences.request_success', 'Sol·licitud enviada correctament') })
    },
    onError: (err: Error) => {
      toast({
        title: t('absences.request_error', 'Error en enviar la sol·licitud'),
        description: err.message,
        variant: 'destructive',
      })
    },
  })
}

export function useCancelMyAbsence() {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: ({ absenceId, reason }: { absenceId: string; reason?: string }) =>
      cancelMyAbsence(absenceId, reason),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: attendanceKeys.all })
      toast({ title: t('absences.withdraw_success', 'Sol·licitud retirada') })
    },
    onError: (err: Error) => {
      toast({
        title: t('absences.withdraw_error', "No s'ha pogut retirar la sol·licitud"),
        description: err.message,
        variant: 'destructive',
      })
    },
  })
}

export function useRevokeAbsence() {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: ({ absenceId, reason }: { absenceId: string; reason: string }) =>
      revokeAbsence(absenceId, reason),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: attendanceKeys.all })
      toast({ title: t('absences.revoke_success', 'Aprovació revocada') })
    },
    onError: (err: Error) => {
      toast({
        title: t('absences.revoke_error', "No s'ha pogut revocar l'absència"),
        description: err.message,
        variant: 'destructive',
      })
    },
  })
}

// ─── Absence Type Configs ─────────────────────────────────────────────────────

export function useAbsenceTypeConfigs(includeIt = true, includePartial = true) {
  return useQuery({
    queryKey: ['attendance', 'absence-type-configs', includeIt, includePartial],
    queryFn: () => listAbsenceTypeConfigs(includeIt, includePartial),
    staleTime: 10 * 60_000,
  })
}

// ─── Register / Close IT (manager) ───────────────────────────────────────────

export function useRegisterIT() {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: registerIT,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: attendanceKeys.all })
      toast({ title: t('absences.it_registered', 'IT registrada correctament') })
    },
    onError: (err: Error) => {
      toast({
        title: t('absences.it_register_error', 'Error en registrar la IT'),
        description: err.message,
        variant: 'destructive',
      })
    },
  })
}

export function useCloseIT() {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: closeIT,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: attendanceKeys.all })
      toast({ title: t('absences.it_closed', 'IT tancada correctament') })
    },
    onError: (err: Error) => {
      toast({
        title: t('absences.it_close_error', 'Error en tancar la IT'),
        description: err.message,
        variant: 'destructive',
      })
    },
  })
}

// ─── Approve / Reject Absence (manager) ──────────────────────────────────────

export function useApproveAbsence() {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: ({
      absenceId,
      newStatus,
      reviewComment,
    }: {
      absenceId: string
      newStatus: 'approved' | 'rejected' | 'cancelled'
      reviewComment?: string
    }) => approveAbsence(absenceId, newStatus, reviewComment),
    onSuccess: (_data, vars) => {
      queryClient.invalidateQueries({ queryKey: attendanceKeys.all })
      const title =
        vars.newStatus === 'approved'
          ? t('absences.approve_success', 'Absència aprovada')
          : vars.newStatus === 'cancelled'
            ? t('absences.cancel_success', 'Absència cancel·lada')
            : t('absences.reject_success', 'Absència rebutjada')
      toast({ title })
    },
    onError: (err: Error) => {
      toast({
        title: t('absences.approve_error', 'Error en processar la sol·licitud'),
        description: err.message,
        variant: 'destructive',
      })
    },
  })
}
