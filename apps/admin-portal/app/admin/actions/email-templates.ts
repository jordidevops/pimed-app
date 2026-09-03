'use server'

import { revalidatePath } from 'next/cache'
import { prisma } from '@/lib/prisma'
import { createSupabaseServerClient } from '@/lib/supabase/server'

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface PlatformEmailTemplate {
  id: string
  name: string
  slug: string
  event_type: string | null
  subject_template: string
  html_body_template: string | null
  text_body_template: string | null
  variables_schema: Record<string, unknown> | null
  is_layout: boolean
  layout_id: string | null
  use_layout: boolean
  is_active: boolean
  is_draft: boolean
  translations: Record<string, { subject?: string; html?: string; text?: string }>
  created_at: string
  updated_at: string
}

export interface PlatformEmailTemplateUpdate {
  name?: string
  subject_template?: string
  html_body_template?: string | null
  text_body_template?: string | null
  layout_id?: string | null
  use_layout?: boolean
  is_active?: boolean
  is_draft?: boolean
  translations?: Record<string, { subject?: string; html?: string; text?: string }>
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
// getPlatformEmailTemplates
// ---------------------------------------------------------------------------

export async function getPlatformEmailTemplates(): Promise<PlatformEmailTemplate[]> {
  await assertAdmin()

  const rows = await prisma.$queryRaw<PlatformEmailTemplate[]>`
    SELECT
      id, name, slug, event_type, subject_template,
      html_body_template, text_body_template, variables_schema,
      is_layout, layout_id, use_layout, is_active, is_draft,
      translations, created_at, updated_at
    FROM data.email_templates
    WHERE is_platform_default = true
    ORDER BY is_layout DESC, name ASC
  `
  return rows
}

// ---------------------------------------------------------------------------
// updatePlatformEmailTemplate
// ---------------------------------------------------------------------------

export async function updatePlatformEmailTemplate(
  id: string,
  updates: PlatformEmailTemplateUpdate,
): Promise<void> {
  await assertAdmin()

  const setClauses: string[] = ['updated_at = now()']
  const values: unknown[] = [id]

  if (updates.name !== undefined) {
    values.push(updates.name)
    setClauses.push(`name = $${values.length}`)
  }
  if (updates.subject_template !== undefined) {
    values.push(updates.subject_template)
    setClauses.push(`subject_template = $${values.length}`)
  }
  if ('html_body_template' in updates) {
    values.push(updates.html_body_template ?? null)
    setClauses.push(`html_body_template = $${values.length}`)
  }
  if ('text_body_template' in updates) {
    values.push(updates.text_body_template ?? null)
    setClauses.push(`text_body_template = $${values.length}`)
  }
  if ('layout_id' in updates) {
    values.push(updates.layout_id ?? null)
    setClauses.push(`layout_id = $${values.length}`)
  }
  if (updates.use_layout !== undefined) {
    values.push(updates.use_layout)
    setClauses.push(`use_layout = $${values.length}`)
  }
  if (updates.is_draft !== undefined) {
    values.push(updates.is_draft)
    setClauses.push(`is_draft = $${values.length}`)
  }
  if (updates.translations !== undefined) {
    values.push(JSON.stringify(updates.translations))
    setClauses.push(`translations = $${values.length}::jsonb`)
  }

  const sql = `
    UPDATE data.email_templates
    SET ${setClauses.join(', ')}
    WHERE id = $1
      AND is_platform_default = true
  `
  await prisma.$executeRawUnsafe(sql, ...values)
  revalidatePath('/dashboard/settings/email')
}
