import { supabase } from '@/lib/supabase'
import { compressImage } from '@/utils/imageOptimizer'
import type { Employee } from './employeesService'

export const EMPLOYEE_PHOTO_BUCKET = 'employee-photos'
export const EMPLOYEE_PHOTO_MAX_BYTES = 2 * 1024 * 1024
export const EMPLOYEE_PHOTO_MIME = ['image/jpeg', 'image/png', 'image/webp'] as const

export function employeePhotoObjectPath(tenantId: string, employeeId: string): string {
  return `${tenantId}/${employeeId}/photo`
}

export function validateEmployeePhotoFile(file: File): string | null {
  if (!EMPLOYEE_PHOTO_MIME.includes(file.type as (typeof EMPLOYEE_PHOTO_MIME)[number])) {
    return 'mime_not_allowed'
  }
  if (file.size > EMPLOYEE_PHOTO_MAX_BYTES) {
    return 'file_too_large'
  }
  return null
}

export async function getEmployeePhotoSignedUrl(
  photoObjectPath: string | null | undefined,
  expiresIn = 3600,
): Promise<string | null> {
  if (!photoObjectPath) return null
  const { data, error } = await supabase.storage
    .from(EMPLOYEE_PHOTO_BUCKET)
    .createSignedUrl(photoObjectPath, expiresIn)
  if (error) throw error
  return data.signedUrl
}

export async function uploadEmployeePhoto(params: {
  tenantId: string
  employeeId: string
  file: File
}): Promise<Employee> {
  const validationError = validateEmployeePhotoFile(params.file)
  if (validationError) {
    throw new Error(validationError)
  }

  const compressed = await compressImage(params.file, {
    maxSizeMB: 0.4,
    maxWidthOrHeight: 800,
  })
  const path = employeePhotoObjectPath(params.tenantId, params.employeeId)

  const { error: uploadError } = await supabase.storage
    .from(EMPLOYEE_PHOTO_BUCKET)
    .upload(path, compressed, {
      upsert: true,
      contentType: compressed.type || params.file.type,
      cacheControl: '3600',
    })
  if (uploadError) throw uploadError

  const { data, error } = await supabase.rpc('set_employee_photo_path', {
    p_employee_id: params.employeeId,
    p_photo_object_path: path,
  })
  if (error) throw error
  return data as Employee
}

export async function clearEmployeePhoto(employeeId: string): Promise<Employee> {
  const { data: emp, error: loadError } = await supabase
    .from('employees')
    .select('photo_object_path')
    .eq('id', employeeId)
    .maybeSingle()
  if (loadError) throw loadError

  if (emp?.photo_object_path) {
    await supabase.storage.from(EMPLOYEE_PHOTO_BUCKET).remove([emp.photo_object_path])
  }

  const { data, error } = await supabase.rpc('set_employee_photo_path', {
    p_employee_id: employeeId,
    p_photo_object_path: null as unknown as string,
  })
  if (error) throw error
  return data as Employee
}
