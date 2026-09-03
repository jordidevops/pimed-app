import { compressImage } from '@/utils/imageOptimizer'
import { supabase } from '@/lib/supabase'

export type FieldMediaCompressionLevel = 'aggressive' | 'balanced' | 'original'

export interface FieldMediaCompressionPrefs {
  enabled: boolean
  level: FieldMediaCompressionLevel
}

/** Platform defaults (admin/system fallback when tenant has no override). */
export const PLATFORM_FIELD_MEDIA_COMPRESSION: FieldMediaCompressionPrefs = {
  enabled: true,
  level: 'balanced',
}

const LEVEL_OPTS: Record<
  Exclude<FieldMediaCompressionLevel, 'original'>,
  { maxSizeMB: number; maxWidthOrHeight: number }
> = {
  aggressive: { maxSizeMB: 0.4, maxWidthOrHeight: 1280 },
  balanced: { maxSizeMB: 1.2, maxWidthOrHeight: 1920 },
}

const LIGHT_OPTS = { maxSizeMB: 0.25, maxWidthOrHeight: 960 }

export function parseFieldMediaCompression(
  settings: Record<string, unknown> | null | undefined,
): FieldMediaCompressionPrefs {
  const block = (settings?.field_media ?? settings?.fieldMedia) as
    | Record<string, unknown>
    | undefined
  const compression = (block?.compression ?? block) as Record<string, unknown> | undefined
  if (!compression || typeof compression !== 'object') {
    return { ...PLATFORM_FIELD_MEDIA_COMPRESSION }
  }
  const levelRaw = String(compression.level ?? PLATFORM_FIELD_MEDIA_COMPRESSION.level)
  const level: FieldMediaCompressionLevel =
    levelRaw === 'aggressive' || levelRaw === 'original' || levelRaw === 'balanced'
      ? levelRaw
      : 'balanced'
  const enabled =
    typeof compression.enabled === 'boolean'
      ? compression.enabled
      : PLATFORM_FIELD_MEDIA_COMPRESSION.enabled
  return { enabled, level }
}

/** Resolve prefs from effective settings RPC (tenant → system merge). */
export async function resolveFieldMediaCompression(
  tenantId: string,
): Promise<FieldMediaCompressionPrefs> {
  try {
    const { data, error } = await supabase.rpc('get_effective_settings', {
      p_tenant_id: tenantId,
    })
    if (error) return { ...PLATFORM_FIELD_MEDIA_COMPRESSION }
    return parseFieldMediaCompression((data as Record<string, unknown>) ?? {})
  } catch {
    return { ...PLATFORM_FIELD_MEDIA_COMPRESSION }
  }
}

export interface PreparedFieldImage {
  /** File to store as the primary node (compressed or original). */
  primary: File
  /** Light derivative when keeping original; null otherwise. */
  light: File | null
  keptOriginal: boolean
}

/** Compress before upload/enqueue. Non-images are returned unchanged. */
export async function prepareFieldImage(
  file: File,
  prefs?: FieldMediaCompressionPrefs,
): Promise<PreparedFieldImage> {
  const resolved = prefs ?? PLATFORM_FIELD_MEDIA_COMPRESSION
  if (!file.type.startsWith('image/') && !/\.(png|jpe?g|gif|webp|heic)$/i.test(file.name)) {
    return { primary: file, light: null, keptOriginal: false }
  }
  if (!resolved.enabled) {
    return { primary: file, light: null, keptOriginal: true }
  }

  if (resolved.level === 'original') {
    let light: File | null = null
    try {
      light = await compressImage(file, LIGHT_OPTS)
    } catch {
      light = null
    }
    return { primary: file, light, keptOriginal: true }
  }

  const opts = LEVEL_OPTS[resolved.level]
  try {
    const primary = await compressImage(file, opts)
    return { primary, light: null, keptOriginal: false }
  } catch {
    return { primary: file, light: null, keptOriginal: false }
  }
}
