import { z } from 'zod'

export const LOCATION_TYPES = ['floor', 'room', 'zone', 'outdoor', 'other'] as const
export const LOCATION_STATUSES = ['active', 'maintenance', 'inactive'] as const

export type LocationType = (typeof LOCATION_TYPES)[number]
export type LocationStatus = (typeof LOCATION_STATUSES)[number]

export const locationSchema = z.object({
  name: z.string().min(1, 'validation.name_required'),
  type: z.enum(LOCATION_TYPES),
  status: z.enum(LOCATION_STATUSES),
  parent_id: z.string().uuid().nullable().optional(),
})

export type LocationFormValues = z.infer<typeof locationSchema>
