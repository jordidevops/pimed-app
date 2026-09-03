import { z } from 'zod'

/** Extreu l'email d'un string en format `email@dom` o `Nom <email@dom>` */
function extractEmail(val: string): string {
  const match = /^.+<([^>]+)>\s*$/.exec(val.trim())
  return match ? match[1].trim() : val.trim()
}

export const emailConfigSchema = z.object({
  default_from_name: z
    .string()
    .refine(
      (s) => s === '' || s.trim().length > 0,
      'El nom del remitent no pot estar format per espais en blanc',
    ),
  default_reply_to: z
    .string()
    .email("Format d'email no vàlid")
    .or(z.literal(''))
    .optional(),
})

export type EmailConfigFormValues = z.infer<typeof emailConfigSchema>

export const senderProfileSchema = z.object({
  label: z.string().min(1, "L'etiqueta és obligatòria").max(50),
  from_name: z
    .string()
    .min(1, 'El nom és obligatori')
    .refine((s) => s.trim().length > 0, 'El nom no pot estar format per espais en blanc'),
  reply_to: z
    .string()
    .email("Format d'email no vàlid")
    .min(1, "L'email de resposta és obligatori"),
})

export type SenderProfileFormValues = z.infer<typeof senderProfileSchema>

const senderProfileWithIdSchema = senderProfileSchema.extend({
  id: z.string().uuid(),
  tag: z.string().optional(),
})

export const senderProfilesArraySchema = z
  .array(senderProfileWithIdSchema)
  .superRefine((profiles, ctx) => {
    const ids = profiles.map((p) => p.id)
    const tags = profiles.map((p) => p.tag).filter(Boolean)
    const duplicateId = ids.find((id, i) => ids.indexOf(id) !== i)
    const duplicateTag = tags.find((tag, i) => tags.indexOf(tag) !== i)
    if (duplicateId) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: `Hi ha perfils amb id duplicat: "${duplicateId}"`,
      })
    }
    if (duplicateTag) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: `Hi ha perfils amb tag duplicat: "${duplicateTag}"`,
      })
    }
  })

export const domainUpdateSchema = z.object({
  default_from_email: z
    .string()
    .refine(
      (s) => !s || /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(extractEmail(s)),
      "Format no vàlid. Usa 'email@domini.com' o 'Nom <email@domini.com>'",
    )
    .nullable()
    .optional(),
  default_from_name: z.string().max(100).nullable().optional(),
  default_reply_to: z
    .string()
    .email("Format d'email no vàlid")
    .or(z.literal(''))
    .optional()
    .nullable(),
})

export type DomainUpdateFormValues = z.infer<typeof domainUpdateSchema>

/** Factory que crea el schema de domini amb validació del domini específic */
export function createDomainUpdateSchema(domainName: string) {
  return z.object({
    default_from_email: z
      .string()
      .refine(
        (s) => {
          if (!s) return true
          const email = extractEmail(s)
          return (
            /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) &&
            email.toLowerCase().endsWith(`@${domainName.toLowerCase()}`)
          )
        },
        `L'adreça ha de pertànyer al domini @${domainName} (ex: noreply@${domainName} o Nom <noreply@${domainName}>)`,
      )
      .nullable()
      .optional(),
    default_from_name: z.string().max(100).nullable().optional(),
    default_reply_to: z
      .string()
      .email("Format d'email no vàlid")
      .or(z.literal(''))
      .nullable()
      .optional(),
  })
}

export const addDomainSchema = z.object({
  domain: z
    .string()
    .min(4, 'El domini és massa curt')
    .regex(
      /^[a-zA-Z0-9][a-zA-Z0-9-]{1,61}[a-zA-Z0-9](\.[a-zA-Z]{2,})+$/,
      'Format de domini no vàlid (ex: empresa.cat)',
    ),
})

export type AddDomainFormValues = z.infer<typeof addDomainSchema>
