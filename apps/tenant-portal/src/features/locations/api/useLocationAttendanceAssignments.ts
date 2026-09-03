import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { useToast } from '@/hooks/use-toast'
import {
  addLocationAttendanceAssignment,
  bulkAddLocationAttendanceAssignments,
  listLocationAttendanceAssignments,
  removeLocationAttendanceAssignment,
  updateLocationAttendanceAssignment,
} from './locationAttendanceAssignmentsService'
import { locationsKeys } from './locationsKeys'

export function useLocationAttendanceAssignments(
  locationId: string | null | undefined,
  includeInactive = false,
) {
  return useQuery({
    queryKey: locationsKeys.attendanceAssignments(locationId ?? '', includeInactive),
    queryFn: () => listLocationAttendanceAssignments(locationId!, includeInactive),
    enabled: !!locationId,
    staleTime: 30_000,
  })
}

function assignmentErrorMessage(err: Error, t: (key: string, fallback: string) => string): string {
  const msg = err.message
  if (msg.includes('insufficient_privilege') || msg.includes('unauthorized')) {
    return t('locations.attendance_assignments.errors.unauthorized', 'No tens permís per gestionar assignacions.')
  }
  if (msg.includes('assignment_already_exists')) {
    return t('locations.attendance_assignments.errors.already_assigned', 'Aquest empleat ja està assignat a la zona.')
  }
  if (msg.includes('employee_site_mismatch')) {
    return t('locations.attendance_assignments.errors.site_mismatch', "L'empleat no pertany al mateix centre que la zona.")
  }
  if (msg.includes('employee_not_active')) {
    return t('locations.attendance_assignments.errors.employee_inactive', "L'empleat no està actiu.")
  }
  if (msg.includes('invalid_assignment_dates')) {
    return t('locations.attendance_assignments.errors.invalid_dates', 'La data de fi ha de ser posterior o igual a la d\'inici.')
  }
  return msg
}

function invalidateAssignments(
  queryClient: ReturnType<typeof useQueryClient>,
  locationId: string | null | undefined,
) {
  if (!locationId) return
  queryClient.invalidateQueries({
    queryKey: ['locations', 'attendance-assignments', locationId],
  })
}

export function useAddLocationAttendanceAssignment(locationId: string | null | undefined) {
  const { t } = useTranslation('locations')
  const { toast } = useToast()
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: addLocationAttendanceAssignment,
    onSuccess: () => {
      invalidateAssignments(queryClient, locationId)
      toast({
        description: t('locations.attendance_assignments.added', 'Empleat assignat a la zona.'),
      })
    },
    onError: (err: Error) => {
      toast({
        variant: 'destructive',
        description: assignmentErrorMessage(err, t),
      })
    },
  })
}

export function useUpdateLocationAttendanceAssignment(locationId: string | null | undefined) {
  const { t } = useTranslation('locations')
  const { toast } = useToast()
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: updateLocationAttendanceAssignment,
    onSuccess: () => {
      invalidateAssignments(queryClient, locationId)
      toast({
        description: t('locations.attendance_assignments.updated', 'Dates d\'assignació actualitzades.'),
      })
    },
    onError: (err: Error) => {
      toast({
        variant: 'destructive',
        description: assignmentErrorMessage(err, t),
      })
    },
  })
}

export function useBulkAddLocationAttendanceAssignments(locationId: string | null | undefined) {
  const { t } = useTranslation('locations')
  const { toast } = useToast()
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: bulkAddLocationAttendanceAssignments,
    onSuccess: (result) => {
      invalidateAssignments(queryClient, locationId)
      const errCount = result.errors?.length ?? 0
      toast({
        description: t(
          'locations.attendance_assignments.bulk_done',
          'Massiu: {{created}} nous, {{updated}} actualitzats{{errors}}.',
          {
            created: result.created,
            updated: result.updated,
            errors: errCount > 0 ? `, ${errCount} errors` : '',
          },
        ),
        variant: errCount > 0 ? 'destructive' : 'default',
      })
    },
    onError: (err: Error) => {
      toast({
        variant: 'destructive',
        description: assignmentErrorMessage(err, t),
      })
    },
  })
}

export function useRemoveLocationAttendanceAssignment(locationId: string | null | undefined) {
  const { t } = useTranslation('locations')
  const { toast } = useToast()
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: removeLocationAttendanceAssignment,
    onSuccess: () => {
      invalidateAssignments(queryClient, locationId)
      toast({
        description: t('locations.attendance_assignments.removed', 'Assignació eliminada.'),
      })
    },
    onError: (err: Error) => {
      toast({
        variant: 'destructive',
        description: assignmentErrorMessage(err, t),
      })
    },
  })
}
