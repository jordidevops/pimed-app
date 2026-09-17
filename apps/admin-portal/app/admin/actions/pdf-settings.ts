'use server'

import { revalidatePath } from 'next/cache'
import { prisma } from '@/lib/prisma'
import { createSupabaseServerClient } from '@/lib/supabase/server'

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface PdfConverterSettings {
  pdf_enabled: boolean
  native_signing_enabled: boolean
  native_evidence_mode: 'detached' | 'embedded' | 'both'
  gotenberg_url: string
  gotenberg_auth_type: 'none' | 'bearer' | 'cf_service_token'
  gotenberg_auth_secret_ref: string | null
  unsigned_pdf_profile: 'pdf'
  signed_pdf_profile: 'pdfa2b'
  audit_pdf_profile: 'pdfa3b'
  paper_size: 'A4' | 'A3' | 'Letter'
  sync_html_max_kb: number
  timeout_ms: number
  keep_native_when_pdf_disabled: boolean
  remote_signing_token_days: number
  legal_footer_text: string
  retention: {
    intermediate_days: number
    job_events_days: number
    audit_pdf_years: number
  }
  retry: {
    max_attempts: number
    backoff_base_seconds: number
  }
  concurrency: {
    global_max: number
    per_tenant_max: number
    batch_size: number
    visibility_timeout: number
    sync_html_timeout: number
    async_docx_timeout: number
    queue_hard_cap: number
    queue_warn_cap: number
  }
}

export interface GotenbergHealthResult {
  accessible: boolean
  version?: string
  latencyMs?: number
  error?: string
}

// ---------------------------------------------------------------------------
// Defaults
// ---------------------------------------------------------------------------

const DEFAULTS: PdfConverterSettings = {
  pdf_enabled: false,
  native_signing_enabled: false,
  native_evidence_mode: 'detached',
  gotenberg_url: 'http://localhost:3007',
  gotenberg_auth_type: 'none',
  gotenberg_auth_secret_ref: null,
  unsigned_pdf_profile: 'pdf',
  signed_pdf_profile: 'pdfa2b',
  audit_pdf_profile: 'pdfa3b',
  paper_size: 'A4',
  sync_html_max_kb: 500,
  timeout_ms: 60000,
  keep_native_when_pdf_disabled: true,
  remote_signing_token_days: 7,
  legal_footer_text: "En signar aquest document, accepteu que la vostra signatura electrònica té plena validesa.",
  retention: {
    intermediate_days: 7,
    job_events_days: 90,
    audit_pdf_years: 5,
  },
  retry: {
    max_attempts: 5,
    backoff_base_seconds: 60,
  },
  concurrency: {
    global_max: 8,
    per_tenant_max: 2,
    batch_size: 20,
    visibility_timeout: 180,
    sync_html_timeout: 25000,
    async_docx_timeout: 90000,
    queue_hard_cap: 300,
    queue_warn_cap: 150,
  },
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
// getPdfConverterSettings
// ---------------------------------------------------------------------------

export async function getPdfConverterSettings(): Promise<PdfConverterSettings> {
  const rows = await prisma.$queryRaw<Array<{ settings: unknown }>>`
    SELECT settings FROM data.system_settings WHERE module = 'pdf_converter'
  `
  const raw = (rows[0]?.settings ?? {}) as Partial<PdfConverterSettings>
  return {
    ...DEFAULTS,
    ...raw,
    retention: { ...DEFAULTS.retention, ...(raw.retention ?? {}) },
    retry:     { ...DEFAULTS.retry,     ...(raw.retry     ?? {}) },
    concurrency: { ...DEFAULTS.concurrency, ...(raw.concurrency ?? {}) },
  }
}

// ---------------------------------------------------------------------------
// updatePdfConverterSettings — actualitza amb merge JSONB
// ---------------------------------------------------------------------------

export async function updatePdfConverterSettings(
  patch: Partial<PdfConverterSettings>,
): Promise<void> {
  const { user } = await assertAdmin()

  // Eliminar el secret de la ref si l'usuari l'envia en clar per error
  // El secret mai es guarda a la BD — només la referència (vault://... o env://...)
  const safePatch = { ...patch }
  if (typeof safePatch.gotenberg_auth_secret_ref === 'string') {
    const ref = safePatch.gotenberg_auth_secret_ref.trim()
    // Acceptar format vault:// o env:// — qualsevol altra cosa s'elimina
    if (ref && !ref.startsWith('vault://') && !ref.startsWith('env://')) {
      safePatch.gotenberg_auth_secret_ref = null
    }
  }

  if (safePatch.pdf_enabled === false) {
    safePatch.native_signing_enabled = false
  }

  if (safePatch.native_signing_enabled === true) {
    const current = await getPdfConverterSettings()
    const pdfEnabled = safePatch.pdf_enabled ?? current.pdf_enabled
    if (!pdfEnabled) {
      throw new Error(
        'No es pot activar la firma pròpia sense la generació PDF activa.',
      )
    }
  }

  await prisma.$executeRaw`
    INSERT INTO data.system_settings (module, settings, updated_by)
    VALUES ('pdf_converter', ${JSON.stringify(safePatch)}::jsonb, ${user.id}::uuid)
    ON CONFLICT (module) DO UPDATE SET
      settings   = data.system_settings.settings || EXCLUDED.settings,
      updated_at = now(),
      updated_by = EXCLUDED.updated_by
  `

  revalidatePath('/dashboard/settings/pdf')
  revalidatePath('/dashboard/settings/signing')
}

// ---------------------------------------------------------------------------
// testGotenbergConnection — crida health check live
// ---------------------------------------------------------------------------

export async function testGotenbergConnection(
  url: string,
  authType: 'none' | 'bearer' | 'cf_service_token',
): Promise<GotenbergHealthResult> {
  await assertAdmin()

  const healthUrl = `${url.replace(/\/$/, '')}/health`
  const t0 = Date.now()

  try {
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), 8000)

    // Capçaleres d'autenticació (no podem llegir el secret des d'aquí; bàsic sense auth per al test)
    const headers: Record<string, string> = {}
    // Nota: el test sense credencials és suficient per verificar connectivitat
    // Un test complet amb credencials requeriria que el frontend passi el secret (no recomanat)

    const res = await fetch(healthUrl, {
      method: 'GET',
      headers,
      signal: controller.signal,
    })
    clearTimeout(timer)

    const latencyMs = Date.now() - t0

    if (!res.ok) {
      return { accessible: false, latencyMs, error: `HTTP ${res.status}` }
    }

    const json = await res.json().catch(() => ({})) as Record<string, unknown>
    const version = typeof json.version === 'string' ? json.version : undefined

    return { accessible: true, version, latencyMs }
  } catch (err) {
    const latencyMs = Date.now() - t0
    return {
      accessible: false,
      latencyMs,
      error: (err as Error).message ?? String(err),
    }
  }
}

// ---------------------------------------------------------------------------
// retryPdfDeadLetters — reintentar jobs DLQ (funcional a Fase 2)
// ---------------------------------------------------------------------------

export async function retryPdfDeadLetters(tenantId?: string): Promise<number> {
  await assertAdmin()

  const rows = await prisma.$queryRaw<Array<{ retry_pdf_dead_letters: number }>>`
    SELECT api.retry_pdf_dead_letters(${tenantId ?? null}::uuid) AS retry_pdf_dead_letters
  `
  return rows[0]?.retry_pdf_dead_letters ?? 0
}
