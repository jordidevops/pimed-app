import { z } from 'zod'

export const BYOS_PROVIDERS = ['s3', 'r2', 'gcs'] as const
export type ByosProvider = (typeof BYOS_PROVIDERS)[number]

/** Providers that require an explicit endpoint_url */
export const ENDPOINT_REQUIRED_PROVIDERS: ByosProvider[] = ['r2', 'gcs']

/** Max file size presets (value in bytes) */
export const MAX_SIZE_PRESETS = [
  { bytes: 10 * 1024 * 1024,        label: '10 MB' },
  { bytes: 25 * 1024 * 1024,        label: '25 MB' },
  { bytes: 50 * 1024 * 1024,        label: '50 MB' },
  { bytes: 100 * 1024 * 1024,       label: '100 MB' },
  { bytes: 250 * 1024 * 1024,       label: '250 MB' },
  { bytes: 500 * 1024 * 1024,       label: '500 MB' },
  { bytes: 1024 * 1024 * 1024,      label: '1 GB' },
] as const

export const byosConfigSchema = z
  .object({
    provider_type: z.enum(['s3', 'r2', 'gcs'], {
      error: 'validation.provider_required',
    }),
    endpoint_url: z.string().optional(),
    region: z.string().optional(),
    bucket_name: z
      .string()
      .min(1, 'validation.bucket_required')
      .min(3, 'validation.bucket_min'),
    access_key: z.string().min(1, 'validation.access_key_required').optional(),
    /**
     * secret_key is only required when the user is creating a new config
     * or has toggled "update credentials". The field is unregistered when
     * hidden (shouldUnregister: true), so undefined passes validation.
     */
    secret_key: z.string().min(1, 'validation.secret_key_required').optional(),
    /** Human-readable label for the drive */
    nickname: z.string().max(50).optional(),
    /** Per-drive MIME type allow-list; null means inherit global defaults */
    allowed_mime_types: z.array(z.string()).optional(),
    /** Max file size for this drive in bytes; null = use drive default */
    max_file_size_bytes: z.number().positive().nullable().optional(),
    /** Optional storage quota cap for this drive in bytes */
    quota_limit_bytes: z.number().positive().nullable().optional(),
  })
  .superRefine((data, ctx) => {
    // endpoint_url is required for R2 and GCS
    if (
      ENDPOINT_REQUIRED_PROVIDERS.includes(data.provider_type) &&
      !data.endpoint_url?.trim()
    ) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'validation.endpoint_required',
        path: ['endpoint_url'],
      })
    }

    // endpoint_url, when provided, must be a valid https:// URL
    if (data.endpoint_url?.trim()) {
      try {
        const url = new URL(data.endpoint_url.trim())
        if (url.protocol !== 'https:') throw new Error()
      } catch {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          message: 'validation.endpoint_url',
          path: ['endpoint_url'],
        })
      }
    }
  })

export type ByosConfigFormValues = z.infer<typeof byosConfigSchema>
