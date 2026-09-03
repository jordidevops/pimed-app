import type { AiModelCapabilitiesRow, AiProvider } from '@/features/ai/types/rpc'

export type ResolvedModelCapabilities = {
  vision: boolean
  tools: boolean
  toolsWithVision: boolean
  streaming: boolean
  maxImageSizeMb: number
  supportedImageMimes: string[]
  maxFileSizeMb: number
  supportedFileMimes: string[]
  source: 'registry' | 'inferred'
}

const DEFAULT_IMAGE_MIMES = ['image/jpeg', 'image/png', 'image/webp']
const DEFAULT_FILE_MIMES = ['application/pdf']

function capabilityKey(provider: AiProvider, modelId: string): string {
  return `${provider}:${modelId.trim().toLowerCase()}`
}

export function buildCapabilitiesIndex(
  rows: AiModelCapabilitiesRow[],
): Map<string, AiModelCapabilitiesRow> {
  const map = new Map<string, AiModelCapabilitiesRow>()
  for (const row of rows) {
    map.set(capabilityKey(row.provider, row.model_id), row)
  }
  return map
}

function inferCapabilities(provider: AiProvider, modelId: string): ResolvedModelCapabilities {
  const id = modelId.toLowerCase()
  let vision = false
  if (provider === 'openai' || provider === 'gemini') {
    vision = /gpt-4o|gpt-4\.1|gpt-4-turbo|gemini|o4-mini|o3/.test(id)
  } else if (provider === 'anthropic') {
    vision = /claude-3|claude-sonnet-4|claude-4/.test(id)
  } else if (provider === 'openrouter') {
    vision = /gpt-4o|gpt-4\.1|gemini|claude-3|claude-sonnet|llava|vision/.test(id)
  }

  const tools = provider !== 'anthropic'
  return {
    vision,
    tools,
    toolsWithVision: vision && tools,
    streaming: true,
    maxImageSizeMb: 5,
    supportedImageMimes: DEFAULT_IMAGE_MIMES,
    maxFileSizeMb: 10,
    supportedFileMimes: DEFAULT_FILE_MIMES,
    source: 'inferred',
  }
}

export function resolveModelCapabilitiesFromIndex(
  index: Map<string, AiModelCapabilitiesRow>,
  provider: AiProvider,
  modelId: string,
): ResolvedModelCapabilities {
  const trimmed = modelId.trim()
  if (!trimmed) return inferCapabilities(provider, trimmed)

  const direct = index.get(capabilityKey(provider, trimmed))
  if (direct) {
    return {
      vision: direct.vision,
      tools: direct.tools,
      toolsWithVision: direct.tools_with_vision,
      streaming: direct.streaming,
      maxImageSizeMb: direct.max_image_size_mb,
      supportedImageMimes: direct.supported_image_mimes?.length
        ? direct.supported_image_mimes
        : DEFAULT_IMAGE_MIMES,
      maxFileSizeMb: direct.max_file_size_mb ?? 10,
      supportedFileMimes: direct.supported_file_mimes?.length
        ? direct.supported_file_mimes
        : DEFAULT_FILE_MIMES,
      source: 'registry',
    }
  }

  if (provider === 'openrouter' && trimmed.includes('/')) {
    const [prefix, inner] = trimmed.split('/', 2)
    const mapped: AiProvider | null = prefix === 'google'
      ? 'gemini'
      : prefix === 'openai'
        ? 'openai'
        : prefix === 'anthropic'
          ? 'anthropic'
          : null
    if (mapped && inner) {
      const alias = index.get(capabilityKey(mapped, inner))
      if (alias) {
        return {
          vision: alias.vision,
          tools: alias.tools,
          toolsWithVision: alias.tools_with_vision,
          streaming: alias.streaming,
          maxImageSizeMb: alias.max_image_size_mb,
          supportedImageMimes: alias.supported_image_mimes?.length
            ? alias.supported_image_mimes
            : DEFAULT_IMAGE_MIMES,
          maxFileSizeMb: alias.max_file_size_mb ?? 10,
          supportedFileMimes: alias.supported_file_mimes?.length
            ? alias.supported_file_mimes
            : DEFAULT_FILE_MIMES,
          source: 'registry',
        }
      }
    }
  }

  return inferCapabilities(provider, trimmed)
}
