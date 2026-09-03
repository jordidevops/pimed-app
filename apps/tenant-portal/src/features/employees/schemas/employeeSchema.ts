import { z } from 'zod'
import {
  optionalEmailField,
  optionalUuidField,
  optionalWeeklyHoursField,
} from './employeeFormFields'

export const EMPLOYEE_STATUSES = ['active', 'inactive', 'terminated'] as const
export type EmployeeStatus = (typeof EMPLOYEE_STATUSES)[number]

export const employeeSchema = z.object({
  full_name: z.string().min(1, 'validation.full_name_required'),
  preferred_name: z.string().nullable().optional(),
  legal_name: z.string().nullable().optional(),
  employee_code: z.string().nullable().optional(),
  email: optionalEmailField(),
  phone: z.string().nullable().optional(),
  document_id: z.string().nullable().optional(),
  job_position_id: optionalUuidField(),
  manager_employee_id: optionalUuidField(),
  status: z.enum(EMPLOYEE_STATUSES),
  starts_on: z.string().nullable().optional(),
  ends_on: z.string().nullable().optional(),
  weekly_hours: optionalWeeklyHoursField(),
  department_id: optionalUuidField(),
  site_id: optionalUuidField(),
  attendance_geo_enabled: z.enum(['inherit', 'true', 'false']).default('inherit'),
  punch_only_at_stations: z.enum(['inherit', 'true', 'false']).default('inherit'),
  attendance_work_profile: z
    .enum(['inherit', 'fixed_site', 'mobile_peripatetic', 'hybrid', 'delivery'])
    .default('inherit'),
})

export type EmployeeFormInput = z.input<typeof employeeSchema>
export type EmployeeFormValues = z.output<typeof employeeSchema>
