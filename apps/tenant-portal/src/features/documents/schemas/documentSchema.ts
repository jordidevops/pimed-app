import { z } from 'zod'

const nullableUuid = z
  .union([z.string().uuid(), z.literal(''), z.null(), z.undefined()])
  .transform((v) => (v === '' || v === null || v === undefined ? null : v))

export const documentSchema = z
  .object({
    title: z.string().min(1, 'validation.title_required').max(255),
    storage_type: z.enum(['native', 'external_link']),
    // URL externa — obligatòria quan storage_type === 'external_link'
    external_url: z.string().url('validation.url_invalid').max(2048).optional().or(z.literal('')),
    folder_id: nullableUuid,
    entity_type: z.string().max(50).optional().nullable(),
    entity_id: nullableUuid,
  })
  .superRefine((data, ctx) => {
    if (data.storage_type === 'external_link' && !data.external_url) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'validation.url_required_for_external',
        path: ['external_url'],
      })
    }
  })

export type DocumentFormInput = z.input<typeof documentSchema>
export type DocumentFormValues = z.output<typeof documentSchema>
