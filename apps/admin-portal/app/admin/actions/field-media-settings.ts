'use server'

import { revalidatePath } from 'next/cache'
import { prisma } from '@/lib/prisma'
import { createSupabaseServerClient } from '@/lib/supabase/server'

export type FieldMediaCompressionLevel = 'aggressive' | 'balanced' | 'original'

export interface FieldMediaPlatformSettings {
  compression: {
    enabled: boolean
    level: FieldMediaCompressionLevel
  }
  upload_mode_default: 'direct' | 'queue'
}

const DEFAULTS: FieldMediaPlatformSettings = {
  compression: { enabled: true, level: 'balanced' },
  upload_mode_default: 'direct',
}

async function assertAdmin() {
  const supabase = await createSupabaseServerClient()
  const {
    data: { user },
    error,
  } = await supabase.auth.getUser()
  if (error || !user) throw new Error('Unauthenticated')
  const role = user.app_metadata?.role as string | undefined
  if (role !== 'admin') throw new Error('Forbidden: requires admin role')
  return { user }
}

export async function getFieldMediaPlatformSettings(): Promise<FieldMediaPlatformSettings> {
  await assertAdmin()
  const rows = await prisma.$queryRaw<Array<{ settings: unknown }>>`
    SELECT settings FROM data.system_settings WHERE module = 'field_media'
  `
  const raw = (rows[0]?.settings ?? {}) as Partial<FieldMediaPlatformSettings>
  return {
    compression: {
      enabled: raw.compression?.enabled ?? DEFAULTS.compression.enabled,
      level: raw.compression?.level ?? DEFAULTS.compression.level,
    },
    upload_mode_default: raw.upload_mode_default ?? DEFAULTS.upload_mode_default,
  }
}

export async function updateFieldMediaPlatformSettings(
  next: FieldMediaPlatformSettings,
): Promise<FieldMediaPlatformSettings> {
  const { user } = await assertAdmin()
  const settings = {
    compression: {
      enabled: !!next.compression?.enabled,
      level:
        next.compression?.level === 'aggressive' ||
        next.compression?.level === 'original' ||
        next.compression?.level === 'balanced'
          ? next.compression.level
          : 'balanced',
    },
    upload_mode_default: next.upload_mode_default === 'queue' ? 'queue' : 'direct',
  }

  await prisma.$executeRaw`
    INSERT INTO data.system_settings (module, settings, updated_by)
    VALUES ('field_media', ${JSON.stringify(settings)}::jsonb, ${user.id}::uuid)
    ON CONFLICT (module) DO UPDATE
    SET settings = EXCLUDED.settings,
        updated_by = EXCLUDED.updated_by,
        updated_at = now()
  `

  // Surface via get_effective_settings (module = defaults)
  await prisma.$executeRaw`
    INSERT INTO data.system_settings (module, settings, updated_by)
    VALUES (
      'defaults',
      jsonb_build_object('field_media', ${JSON.stringify(settings)}::jsonb),
      ${user.id}::uuid
    )
    ON CONFLICT (module) DO UPDATE
    SET settings = data.system_settings.settings || EXCLUDED.settings,
        updated_by = EXCLUDED.updated_by,
        updated_at = now()
  `

  revalidatePath('/dashboard/settings/field-media')
  return settings
}
