import { z } from 'zod'

export const departmentSchema = z.object({
  name: z.string().min(1, 'validation.name_required'),
  code: z.string().max(20).optional().or(z.literal('')),
  parent_id: z.string().uuid().nullable().optional(),
  manager_employee_id: z.string().uuid().nullable().optional(),
  attendance_geo_enabled: z.enum(['inherit', 'true', 'false']).default('inherit'),
})

export type DepartmentFormValues = z.infer<typeof departmentSchema>
