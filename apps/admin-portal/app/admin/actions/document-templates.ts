'use server'

import { revalidatePath } from 'next/cache'
import { prisma } from '@/lib/prisma'
import { createSupabaseServerClient } from '@/lib/supabase/server'
import { createSupabaseAdminClient } from '@/lib/supabase/admin'

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface PlatformDocumentTemplateLocale {
  id: string
  template_id: string
  locale: string
  storage_path: string | null
  mime_type: string | null
  variables_schema: Record<string, unknown>
  signing_roles_schema: Record<string, unknown>
  /** NULL en consultes de llista — carregat sota demanda via getPlatformDocumentTemplateLocaleHtmlContent */
  html_content: string | null
  is_active: boolean
  created_at: string
  updated_at: string
}

export interface PlatformDocumentTemplate {
  id: string
  name: string
  description: string | null
  category: string | null
  template_type: 'docx' | 'html'
  is_active: boolean
  cloned_from_id: string | null
  created_at: string
  updated_at: string
  locales: PlatformDocumentTemplateLocale[]
}

export interface PlatformDocumentTemplateCreate {
  name: string
  description?: string
  category?: string
  template_type?: 'docx' | 'html'
}

export interface PlatformDocumentTemplateUpdate {
  name?: string
  description?: string | null
  category?: string | null
  is_active?: boolean
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

async function assertPlatformTemplate(templateId: string): Promise<{ template_type: 'docx' | 'html' }> {
  const rows = await prisma.$queryRaw<{ id: string; template_type: string }[]>`
    SELECT id, template_type
    FROM data.document_templates
    WHERE id = ${templateId}
      AND is_platform_default = true
    LIMIT 1
  `

  if (!rows[0]?.id) {
    throw new Error('Template not found or not a platform template')
  }
  return { template_type: rows[0].template_type as 'docx' | 'html' }
}

// ---------------------------------------------------------------------------
// getPlatformDocumentTemplates
// ---------------------------------------------------------------------------

export async function getPlatformDocumentTemplates(): Promise<PlatformDocumentTemplate[]> {
  await assertAdmin()

  const templates = await prisma.$queryRaw<Omit<PlatformDocumentTemplate, 'locales'>[]>`
    SELECT id, name, description, category, template_type, is_active, cloned_from_id,
           created_at::text, updated_at::text
    FROM data.document_templates
    WHERE is_platform_default = true
    ORDER BY category ASC NULLS LAST, name ASC
  `

  const locales = await prisma.$queryRaw<PlatformDocumentTemplateLocale[]>`
    SELECT dtl.id, dtl.template_id, dtl.locale, dtl.storage_path,
           dtl.mime_type, dtl.variables_schema, dtl.signing_roles_schema,
           NULL::text AS html_content,
           dtl.is_active,
           dtl.created_at::text, dtl.updated_at::text
    FROM data.document_template_locales dtl
    JOIN data.document_templates dt ON dt.id = dtl.template_id
    WHERE dt.is_platform_default = true
    ORDER BY dtl.locale ASC
  `

  const localesByTemplateId = new Map<string, PlatformDocumentTemplateLocale[]>()
  for (const locale of locales) {
    const bucket = localesByTemplateId.get(locale.template_id)
    if (bucket) {
      bucket.push(locale)
    } else {
      localesByTemplateId.set(locale.template_id, [locale])
    }
  }

  return templates.map((tpl) => ({
    ...tpl,
    locales: localesByTemplateId.get(tpl.id) ?? [],
  }))
}

// ---------------------------------------------------------------------------
// createPlatformDocumentTemplate
// ---------------------------------------------------------------------------

export async function createPlatformDocumentTemplate(
  data: PlatformDocumentTemplateCreate,
): Promise<string> {
  await assertAdmin()

  const rows = await prisma.$queryRaw<{ id: string }[]>`
    INSERT INTO data.document_templates (name, description, category, template_type, is_platform_default, is_active)
    VALUES (${data.name}, ${data.description ?? null}, ${data.category ?? null}, ${data.template_type ?? 'docx'}, true, true)
    RETURNING id
  `

  revalidatePath('/dashboard/settings/signing')
  revalidatePath('/dashboard/settings/templates')
  return rows[0].id
}

// ---------------------------------------------------------------------------
// updatePlatformDocumentTemplate
// ---------------------------------------------------------------------------

export async function updatePlatformDocumentTemplate(
  id: string,
  updates: PlatformDocumentTemplateUpdate,
): Promise<void> {
  await assertAdmin()

  const setClauses: string[] = ['updated_at = now()']
  const values: unknown[] = [id]

  if (updates.name !== undefined) {
    values.push(updates.name)
    setClauses.push(`name = $${values.length}`)
  }
  if ('description' in updates) {
    values.push(updates.description ?? null)
    setClauses.push(`description = $${values.length}`)
  }
  if ('category' in updates) {
    values.push(updates.category ?? null)
    setClauses.push(`category = $${values.length}`)
  }
  if (updates.is_active !== undefined) {
    values.push(updates.is_active)
    setClauses.push(`is_active = $${values.length}`)
  }

  const sql = `
    UPDATE data.document_templates
    SET ${setClauses.join(', ')}
    WHERE id = $1 AND is_platform_default = true
  `
  await prisma.$executeRawUnsafe(sql, ...values)
  revalidatePath('/dashboard/settings/signing')
  revalidatePath('/dashboard/settings/templates')
}

// ---------------------------------------------------------------------------
// deletePlatformDocumentTemplate
// ---------------------------------------------------------------------------

export async function deletePlatformDocumentTemplate(id: string): Promise<void> {
  await assertAdmin()
  await assertPlatformTemplate(id)

  const localeRows = await prisma.$queryRaw<{ storage_path: string | null }[]>`
    SELECT dtl.storage_path
    FROM data.document_template_locales dtl
    WHERE dtl.template_id = ${id}
      AND dtl.storage_path IS NOT NULL
  `

  const paths = localeRows
    .map((l) => l.storage_path)
    .filter((p): p is string => p !== null)

  if (paths.length > 0) {
    const adminClient = createSupabaseAdminClient()
    const { error } = await adminClient.storage.from('document-templates').remove(paths)
    if (error) {
      throw new Error(`Storage delete failed: ${error.message}`)
    }
  }

  await prisma.$executeRaw`
    DELETE FROM data.document_templates WHERE id = ${id} AND is_platform_default = true
  `

  revalidatePath('/dashboard/settings/signing')
  revalidatePath('/dashboard/settings/templates')
}

// ---------------------------------------------------------------------------
// uploadPlatformTemplateLocaleFile
// Upload DOCX/PDF to Storage bucket using service_role client (bypasses RLS
// tenant-folder policies). Returns the storage path and detected mime type.
// ---------------------------------------------------------------------------

export async function uploadPlatformTemplateLocaleFile(
  formData: FormData,
): Promise<{ path: string; mimeType: string }> {
  await assertAdmin()

  const file = formData.get('file') as File | null
  const templateId = formData.get('template_id') as string | null
  const locale = formData.get('locale') as string | null

  if (!file || !templateId || !locale) {
    throw new Error('Missing required fields: file, template_id, locale')
  }

  const { template_type } = await assertPlatformTemplate(templateId)
  if (template_type === 'html') {
    throw new Error('HTML templates do not use file uploads. Set html_content instead.')
  }

  const normalizedLocale = locale.trim().toLowerCase()
  const allowedLocales = new Set(['ca', 'es', 'en'])
  if (!allowedLocales.has(normalizedLocale)) {
    throw new Error('Invalid locale. Allowed locales: ca, es, en')
  }

  const allowedExtensions = new Set(['docx'])
  const allowedMimeTypes = new Set([
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  ])

  const ext = file.name.split('.').pop()?.toLowerCase() ?? 'docx'
  if (!allowedExtensions.has(ext)) {
    throw new Error('Invalid file extension. Only DOCX is allowed')
  }

  const mimeType = file.type ||
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document'

  if (!allowedMimeTypes.has(mimeType)) {
    throw new Error('Invalid mime type. Only DOCX is allowed')
  }

  const path = `platform/${templateId}/${normalizedLocale}.${ext}`

  const adminClient = createSupabaseAdminClient()
  const { error } = await adminClient.storage
    .from('document-templates')
    .upload(path, file, { upsert: true, contentType: mimeType })

  if (error) throw new Error(`Storage upload failed: ${error.message}`)

  return { path, mimeType }
}

// ---------------------------------------------------------------------------
// upsertPlatformDocumentTemplateLocale
// Inserts or updates locale metadata (variables_schema, is_active, path).
// ---------------------------------------------------------------------------

export async function upsertPlatformDocumentTemplateLocale(
  templateId: string,
  locale: string,
  data: {
    variables_schema?: Record<string, unknown>
    signing_roles_schema?: Record<string, unknown>
    html_content?: string | null
    is_active?: boolean
    storage_path?: string | null
    mime_type?: string | null
  },
): Promise<PlatformDocumentTemplateLocale> {
  await assertAdmin()

  const { template_type } = await assertPlatformTemplate(templateId)

  const normalizedLocale = locale.trim().toLowerCase()
  const allowedLocales = new Set(['ca', 'es', 'en'])
  if (!allowedLocales.has(normalizedLocale)) {
    throw new Error('Invalid locale. Allowed locales: ca, es, en')
  }

  // Validate mime_type is consistent with template_type
  if (template_type === 'html' && data.mime_type && data.mime_type !== 'text/html') {
    throw new Error('HTML templates only accept text/html locales')
  }
  if (template_type === 'docx' && data.mime_type === 'text/html') {
    throw new Error('DOCX templates do not accept HTML locales')
  }

  const rows = await prisma.$queryRaw<PlatformDocumentTemplateLocale[]>`
    INSERT INTO data.document_template_locales
      (template_id, locale, variables_schema, signing_roles_schema, html_content, is_active, storage_path, mime_type)
    VALUES (
      ${templateId},
      ${normalizedLocale},
      ${JSON.stringify(data.variables_schema ?? {})}::jsonb,
      ${JSON.stringify(data.signing_roles_schema ?? {})}::jsonb,
      ${data.html_content ?? null},
      ${data.is_active ?? true},
      ${data.storage_path ?? null},
      ${data.mime_type ?? null}
    )
    ON CONFLICT (template_id, locale)
    DO UPDATE SET
      variables_schema     = EXCLUDED.variables_schema,
      signing_roles_schema = EXCLUDED.signing_roles_schema,
      is_active            = EXCLUDED.is_active,
      storage_path         = COALESCE(EXCLUDED.storage_path, document_template_locales.storage_path),
      mime_type            = COALESCE(EXCLUDED.mime_type, document_template_locales.mime_type),
      html_content         = COALESCE(EXCLUDED.html_content, document_template_locales.html_content),
      updated_at           = now()
    RETURNING id, template_id, locale, storage_path, mime_type, variables_schema,
              signing_roles_schema, NULL::text AS html_content, is_active,
              created_at::text, updated_at::text
  `

  revalidatePath('/dashboard/settings/signing')
  revalidatePath('/dashboard/settings/templates')
  return rows[0]
}

// ---------------------------------------------------------------------------
// deletePlatformDocumentTemplateLocale
// ---------------------------------------------------------------------------

export async function deletePlatformDocumentTemplateLocale(
  localeId: string,
): Promise<void> {
  await assertAdmin()

  const rows = await prisma.$queryRaw<{ id: string; storage_path: string | null }[]>`
    SELECT dtl.id, dtl.storage_path
    FROM data.document_template_locales dtl
    JOIN data.document_templates dt ON dt.id = dtl.template_id
    WHERE dtl.id = ${localeId}
      AND dt.is_platform_default = true
    LIMIT 1
  `

  if (!rows[0]?.id) {
    throw new Error('Locale not found or not linked to a platform template')
  }

  const storagePathFromDb = rows[0].storage_path

  if (storagePathFromDb) {
    const adminClient = createSupabaseAdminClient()
    const { error } = await adminClient.storage.from('document-templates').remove([storagePathFromDb])
    if (error) {
      throw new Error(`Storage delete failed: ${error.message}`)
    }
  }

  await prisma.$executeRaw`
    DELETE FROM data.document_template_locales WHERE id = ${localeId}
  `

  revalidatePath('/dashboard/settings/signing')
  revalidatePath('/dashboard/settings/templates')
}

// ---------------------------------------------------------------------------
// getPlatformDocumentTemplateLocaleHtmlContent
// Carrega html_content sota demanda (pot ser fins a 500 KB; s'exclou de la llista).
// ---------------------------------------------------------------------------

export async function getPlatformDocumentTemplateLocaleHtmlContent(
  localeId: string,
): Promise<string | null> {
  await assertAdmin()

  const rows = await prisma.$queryRaw<{ html_content: string | null }[]>`
    SELECT dtl.html_content
    FROM data.document_template_locales dtl
    JOIN data.document_templates dt ON dt.id = dtl.template_id
    WHERE dtl.id = ${localeId}
      AND dt.is_platform_default = true
    LIMIT 1
  `
  return rows[0]?.html_content ?? null
}

// ---------------------------------------------------------------------------
// getPlatformTemplateLocaleDownloadUrl
// Genera una URL signada (5 min) per descarregar el fitxer DOCX d'un locale.
// ---------------------------------------------------------------------------

export async function getPlatformTemplateLocaleDownloadUrl(
  localeId: string,
): Promise<{ url: string; filename: string }> {
  await assertAdmin()

  const rows = await prisma.$queryRaw<{ storage_path: string | null; locale: string }[]>`
    SELECT dtl.storage_path, dtl.locale
    FROM data.document_template_locales dtl
    JOIN data.document_templates dt ON dt.id = dtl.template_id
    WHERE dtl.id = ${localeId}
      AND dt.is_platform_default = true
    LIMIT 1
  `

  const row = rows[0]
  if (!row?.storage_path) {
    throw new Error('Locale sense fitxer al Storage')
  }

  const adminClient = createSupabaseAdminClient()
  const { data, error } = await adminClient.storage
    .from('document-templates')
    .createSignedUrl(row.storage_path, 300) // 5 minuts

  if (error || !data?.signedUrl) {
    throw new Error(`Error generant URL de descàrrega: ${error?.message ?? 'desconegut'}`)
  }

  const filename = row.storage_path.split('/').pop() ?? `template_${row.locale}.docx`
  return { url: data.signedUrl, filename }
}
