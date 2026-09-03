import { z } from 'zod'

const entityTypeSchema = z.enum([
  'employee', 'contact', 'user', 'person', 'site', 'asset', 'tenant', 'catalog_item',
])

export const aiRoleItemSchema = z.object({
  key:         z.string().min(1),
  label:       z.string().min(1),
  entity_type: entityTypeSchema.optional(),
  for_signing: z.boolean().optional(),
  order:       z.number().int().optional(),
})

export const aiVariableItemSchema = z.object({
  key:      z.string().min(1),
  label:    z.string().min(1),
  type:     z.enum(['string', 'number', 'date', 'text']).default('string'),
  required: z.boolean().optional(),
  role:     z.string().nullable().optional(),
  order:    z.number().int().optional(),
})

export const aiLocalePayloadSchema = z.object({
  locale:    z.string().min(2).optional(),
  format:    z.enum(['html', 'docx']).default('html'),
  roles:     z.array(aiRoleItemSchema).default([]),
  variables: z.array(aiVariableItemSchema).default([]),
  content:   z.string().optional(),
})

export const aiImportRootSchema = z.union([
  aiLocalePayloadSchema,
  z.object({ locales: z.array(aiLocalePayloadSchema).min(1) }),
])

export type AIRoleItem = z.infer<typeof aiRoleItemSchema>
export type AIVariableItem = z.infer<typeof aiVariableItemSchema>
export type AILocalePayload = z.infer<typeof aiLocalePayloadSchema>

export function unwrapAiImportPayload(raw: unknown): AILocalePayload {
  const parsed = aiImportRootSchema.parse(raw)
  if ('locales' in parsed) {
    if (parsed.locales.length > 1) {
      throw new Error('MULTIPLE_LOCALES')
    }
    return parsed.locales[0]
  }
  return parsed
}
