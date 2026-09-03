'use server'

import { revalidatePath } from 'next/cache'
import { prisma } from '@/lib/prisma'
import { createSupabaseServerClient } from '@/lib/supabase/server'

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface RateLimitingSettings {
  rate_limiting_enabled: boolean
  rate_limit_engine: 'redis' | 'postgres'
  fallback_to_postgres: boolean
}

export interface EmailModuleSettings {
  platform_default_domain: string
  platform_default_from_email: string
  platform_default_from_name: string
}

// ---------------------------------------------------------------------------
// Defaults
// ---------------------------------------------------------------------------

const RATE_LIMITING_DEFAULTS: RateLimitingSettings = {
  rate_limiting_enabled: true,
  rate_limit_engine: 'postgres',
  fallback_to_postgres: true,
}

const EMAIL_MODULE_DEFAULTS: EmailModuleSettings = {
  platform_default_domain: '',
  platform_default_from_email: '',
  platform_default_from_name: '',
}

// ---------------------------------------------------------------------------
// Auth guard
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// getRateLimitingSettings
// ---------------------------------------------------------------------------

export async function getRateLimitingSettings(): Promise<RateLimitingSettings> {
  const rows = await prisma.$queryRaw<Array<{ settings: unknown }>>`
    SELECT settings FROM data.system_settings WHERE module = 'rate_limiting'
  `
  const raw = (rows[0]?.settings ?? {}) as Partial<RateLimitingSettings>
  return { ...RATE_LIMITING_DEFAULTS, ...raw }
}

// ---------------------------------------------------------------------------
// updateRateLimitingSettings
// ---------------------------------------------------------------------------

export async function updateRateLimitingSettings(
  settings: RateLimitingSettings,
): Promise<void> {
  const { user } = await assertAdmin()

  await prisma.$executeRaw`
    INSERT INTO data.system_settings (module, settings, updated_by)
    VALUES ('rate_limiting', ${JSON.stringify(settings)}::jsonb, ${user.id}::uuid)
    ON CONFLICT (module) DO UPDATE SET
      settings   = EXCLUDED.settings,
      updated_at = now(),
      updated_by = EXCLUDED.updated_by
  `

  revalidatePath('/dashboard/settings/email')
}

// ---------------------------------------------------------------------------
// getEmailModuleSettings
// ---------------------------------------------------------------------------

export async function getEmailModuleSettings(): Promise<EmailModuleSettings> {
  const rows = await prisma.$queryRaw<Array<{ settings: unknown }>>`
    SELECT settings FROM data.system_settings WHERE module = 'email'
  `
  const raw = (rows[0]?.settings ?? {}) as Partial<EmailModuleSettings>
  return { ...EMAIL_MODULE_DEFAULTS, ...raw }
}

// ---------------------------------------------------------------------------
// updateEmailModuleSettings
// ---------------------------------------------------------------------------

export async function updateEmailModuleSettings(
  settings: EmailModuleSettings,
): Promise<void> {
  const { user } = await assertAdmin()

  await prisma.$executeRaw`
    INSERT INTO data.system_settings (module, settings, updated_by)
    VALUES ('email', ${JSON.stringify(settings)}::jsonb, ${user.id}::uuid)
    ON CONFLICT (module) DO UPDATE SET
      settings   = EXCLUDED.settings,
      updated_at = now(),
      updated_by = EXCLUDED.updated_by
  `

  revalidatePath('/dashboard/settings/email')
}

