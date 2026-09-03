import { z } from 'zod'

/** UUIDs del projecte (inclosos seeds amb versió 0) no passen z.string().uuid() de Zod 4. */
export const RelaxedUuidSchema = z.string().regex(
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
  'Invalid id',
)

export const ChartDatasetSchema = z.object({
  label: z.string(),
  values: z.array(z.number()),
})

export const ChartUiBlockSchema = z.object({
  type: z.literal('chart'),
  chartType: z.enum(['bar', 'line', 'pie']),
  title: z.string(),
  labels: z.array(z.string()),
  datasets: z.array(ChartDatasetSchema).min(1),
}).superRefine((data, ctx) => {
  for (const [index, dataset] of data.datasets.entries()) {
    if (dataset.values.length !== data.labels.length) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'invalid_lengths',
        path: ['datasets', index, 'values'],
      })
    }
  }
})

export type ChartUiBlock = z.infer<typeof ChartUiBlockSchema>

export const DocumentGeneratorUiBlockSchema = z.object({
  type: z.literal('document_generator'),
  templateLocaleId: RelaxedUuidSchema,
  templateName: z.string(),
  documentTitle: z.string().optional(),
  locale: z.string().optional(),
  mimeType: z.string().optional(),
  source: z.record(z.string(), z.unknown()),
})

export type DocumentGeneratorUiBlock = z.infer<typeof DocumentGeneratorUiBlockSchema>

export const DocumentResultUiBlockSchema = z.object({
  type: z.literal('document_result'),
  success: z.boolean(),
  documentId: RelaxedUuidSchema.optional(),
  documentTitle: z.string().optional(),
  outputFormat: z.enum(['pdf', 'docx', 'html']).optional(),
  templateName: z.string().optional(),
  error: z.string().optional(),
})

export type DocumentResultUiBlock = z.infer<typeof DocumentResultUiBlockSchema>

export type AiChatUiBlock = ChartUiBlock | DocumentGeneratorUiBlock | DocumentResultUiBlock

/** Parser manual: discriminatedUnion no és compatible amb superRefine (Zod 4). */
export function parseUiBlock(raw: unknown): AiChatUiBlock | null {
  if (!raw || typeof raw !== 'object') return null
  const type = (raw as { type?: unknown }).type
  if (type === 'chart') {
    const parsed = ChartUiBlockSchema.safeParse(raw)
    return parsed.success ? parsed.data : null
  }
  if (type === 'document_generator') {
    const parsed = DocumentGeneratorUiBlockSchema.safeParse(raw)
    return parsed.success ? parsed.data : null
  }
  if (type === 'document_result') {
    const parsed = DocumentResultUiBlockSchema.safeParse(raw)
    return parsed.success ? parsed.data : null
  }
  return null
}

export function parseUiBlocks(raw: unknown): AiChatUiBlock[] {
  if (!Array.isArray(raw)) return []
  const blocks: AiChatUiBlock[] = []
  for (const item of raw) {
    const parsed = parseUiBlock(item)
    if (parsed) blocks.push(parsed)
  }
  return blocks
}

export function parseUiBlocksFromPayload(
  payload: Record<string, unknown> | null | undefined,
): AiChatUiBlock[] {
  return parseUiBlocks(payload?.ui_blocks)
}
