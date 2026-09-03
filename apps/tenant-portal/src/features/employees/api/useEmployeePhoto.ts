import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  clearEmployeePhoto,
  getEmployeePhotoSignedUrl,
  uploadEmployeePhoto,
} from './employeePhotoService'

export function useEmployeePhotoUrl(photoObjectPath: string | null | undefined) {
  return useQuery({
    queryKey: ['employee-photo-url', photoObjectPath],
    queryFn: () => getEmployeePhotoSignedUrl(photoObjectPath),
    enabled: !!photoObjectPath,
    staleTime: 5 * 60 * 1000,
  })
}

export function useUploadEmployeePhoto(employeeId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (params: { tenantId: string; file: File }) =>
      uploadEmployeePhoto({ employeeId, tenantId: params.tenantId, file: params.file }),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['employees'] })
      void qc.invalidateQueries({ queryKey: ['employee-photo-url'] })
    },
  })
}

export function useClearEmployeePhoto(employeeId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: () => clearEmployeePhoto(employeeId),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['employees'] })
      void qc.invalidateQueries({ queryKey: ['employee-photo-url'] })
    },
  })
}

export function useEmployeeAvatarSrc(
  photoObjectPath: string | null | undefined,
  fullName: string | null | undefined,
) {
  const { data: url } = useEmployeePhotoUrl(photoObjectPath)
  const initials = (fullName ?? '?').trim().slice(0, 2).toUpperCase() || '?'
  return { src: url ?? null, initials }
}
