/**
 * POST /api/recruitment/apply
 * Multipart: CV + camps + Turnstile + honeypot → storage + submit_job_application
 */

import { NextRequest, NextResponse } from 'next/server'
import { createHash, randomUUID } from 'crypto'
import { z } from 'zod'
import { createServiceRoleClient } from '@/lib/supabase-service'
import { verifyTurnstileToken } from '@/lib/turnstile'
import { checkRateLimit } from '@/lib/rate-limit'

export const runtime = 'nodejs'

const ALLOWED_MIME = new Set([
  'application/pdf',
  'application/msword',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
])

const MAX_CV_BYTES = 10 * 1024 * 1024

const FieldsSchema = z.object({
  siteId: z.string().uuid(),
  jobPostingId: z.string().uuid(),
  fullName: z.string().min(1).max(120),
  email: z.string().email().max(254),
  phone: z.string().max(30).optional().or(z.literal('')),
  coverMessage: z.string().max(4000).optional().or(z.literal('')),
  source: z.enum(['web', 'qr', 'whatsapp', 'email', 'manual', 'csv_import']).default('web'),
  retentionPreference: z.enum(['delete_after_months', 'delete_on_process_end']),
  retentionMonths: z.coerce.number().int().min(1).max(12).optional(),
  privacyAccepted: z.enum(['true', '1']),
  locale: z.enum(['ca', 'es', 'en']).default('ca'),
  turnstileToken: z.string().min(1),
  _hp: z.string().optional().default(''),
})

function getClientIp(req: NextRequest): string {
  return (
    req.headers.get('cf-connecting-ip') ??
    req.headers.get('x-vercel-forwarded-for') ??
    req.headers.get('x-forwarded-for')?.split(',')[0]?.trim() ??
    'unknown'
  )
}

function extForMime(mime: string): string {
  if (mime === 'application/pdf') return 'pdf'
  if (mime === 'application/msword') return 'doc'
  return 'docx'
}

export async function POST(req: NextRequest): Promise<NextResponse> {
  try {
    return await handlePost(req)
  } catch (err) {
    console.error('[api/recruitment/apply] Unhandled:', err)
    return NextResponse.json(
      { error: 'internal_error', message: 'Error intern. Torna-ho a intentar.' },
      { status: 500 },
    )
  }
}

async function handlePost(req: NextRequest): Promise<NextResponse> {
  const form = await req.formData()
  const raw: Record<string, string> = {}
  for (const [key, value] of form.entries()) {
    if (typeof value === 'string') raw[key] = value
  }

  const parsed = FieldsSchema.safeParse(raw)
  if (!parsed.success) {
    return NextResponse.json(
      {
        error: 'validation_error',
        issues: parsed.error.issues.map((i) => ({
          field: i.path.join('.'),
          message: i.message,
        })),
      },
      { status: 422 },
    )
  }

  const data = parsed.data
  if (data._hp !== '') {
    return NextResponse.json({ application_id: null }, { status: 200 })
  }

  const cv = form.get('cv')
  if (!(cv instanceof File) || cv.size === 0) {
    return NextResponse.json(
      { error: 'validation_error', message: 'El CV és obligatori.' },
      { status: 422 },
    )
  }
  if (cv.size > MAX_CV_BYTES) {
    return NextResponse.json(
      { error: 'validation_error', message: 'El CV supera el límit de 10 MB.' },
      { status: 422 },
    )
  }
  if (!ALLOWED_MIME.has(cv.type)) {
    return NextResponse.json(
      { error: 'validation_error', message: 'Format de CV no permès (PDF o Word).' },
      { status: 422 },
    )
  }

  const clientIp = getClientIp(req)
  const host = req.headers.get('host') ?? 'unknown'
  const withinLimit = await checkRateLimit(
    `${clientIp}:${host}:rec:${data.siteId}`,
    5,
    60_000,
  )
  if (!withinLimit) {
    return NextResponse.json(
      { error: 'rate_limited', message: 'Massa peticions. Torna a intentar-ho en un minut.' },
      { status: 429 },
    )
  }

  const turnstileOk = await verifyTurnstileToken(data.turnstileToken, clientIp)
  if (!turnstileOk) {
    return NextResponse.json(
      { error: 'turnstile_failed', message: 'Verificació de seguretat fallida.' },
      { status: 422 },
    )
  }

  const window5min = Math.floor(Date.now() / (5 * 60_000))
  const idempotencyKey = createHash('sha256')
    .update(
      `${data.siteId}:${data.jobPostingId}:${data.email.toLowerCase().trim()}:${window5min}`,
    )
    .digest('hex')

  const storagePath = `${data.siteId}/${data.jobPostingId}/${randomUUID()}.${extForMime(cv.type)}`
  const admin = createServiceRoleClient()
  const buffer = Buffer.from(await cv.arrayBuffer())
  const { error: uploadErr } = await admin.storage
    .from('recruitment-cvs')
    .upload(storagePath, buffer, {
      contentType: cv.type,
      upsert: false,
    })

  if (uploadErr) {
    console.error('[api/recruitment/apply] upload:', uploadErr)
    return NextResponse.json(
      { error: 'upload_failed', message: 'No s\'ha pogut pujar el CV.' },
      { status: 500 },
    )
  }

  // Never trust client Origin (token phishing). Prefer explicit portal base URL.
  const verifyBaseUrl = (
    process.env.NEXT_PUBLIC_SITE_URL ||
    process.env.PUBLIC_PORTAL_BASE_URL ||
    req.nextUrl.origin
  ).replace(/\/$/, '')

  async function removeUploadedCv() {
    try {
      await admin.storage.from('recruitment-cvs').remove([storagePath])
    } catch (cleanupErr) {
      console.error('[api/recruitment/apply] CV cleanup:', cleanupErr)
    }
  }

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const { data: result, error } = await (admin as any).rpc('submit_job_application', {
    p_public_site_id: data.siteId,
    p_job_posting_id: data.jobPostingId,
    p_idempotency_key: idempotencyKey,
    p_full_name: data.fullName.trim(),
    p_email: data.email.trim().toLowerCase(),
    p_phone: data.phone?.trim() || null,
    p_cover_message: data.coverMessage?.trim() || null,
    p_source: data.source,
    p_retention_preference: data.retentionPreference,
    p_retention_months:
      data.retentionPreference === 'delete_after_months'
        ? data.retentionMonths ?? 12
        : null,
    p_cv_storage_path: storagePath,
    p_legal_notice_version: 'v2',
    p_privacy_accepted: true,
    p_locale: data.locale,
    p_verify_base_url: verifyBaseUrl,
  })

  if (error) {
    await removeUploadedCv()
    const normalized = [error.code, error.message, error.details, error.hint]
      .filter(Boolean)
      .join(' | ')
      .toLowerCase()

    if (
      normalized.includes('privacy_not_accepted') ||
      normalized.includes('invalid_input')
    ) {
      return NextResponse.json(
        { error: 'validation_error', message: error.hint || error.message },
        { status: 422 },
      )
    }
    if (
      normalized.includes('site_not_published') ||
      normalized.includes('module_not_enabled') ||
      normalized.includes('posting_not')
    ) {
      return NextResponse.json(
        { error: 'submission_rejected', message: 'Aquesta oferta no accepta candidatures.' },
        { status: 403 },
      )
    }
    console.error('[api/recruitment/apply] RPC:', error)
    return NextResponse.json(
      { error: 'internal_error', message: 'Error intern. Torna-ho a intentar.' },
      { status: 500 },
    )
  }

  // Duplicate: RPC deletes orphan path; belt-and-suspenders cleanup
  if (result && typeof result === 'object' && (result as { duplicate?: boolean }).duplicate) {
    await removeUploadedCv()
  }

  return NextResponse.json(result, { status: 201 })
}
