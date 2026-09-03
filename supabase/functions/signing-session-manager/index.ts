import { corsHeaders } from '../_shared/cors.ts'
import { createAdminClient, createUserClient } from '../_shared/supabase.ts'
import { deleteStagingPdf } from '../_shared/native-signing-staging.ts'
import { kickPdfQueueWorker } from '../_shared/kick-pdf-queue.ts'
import { initObservability, captureException } from '../_shared/observability/system-error-tracker.ts'
import { log } from '../_shared/observability/structured-logger.ts'
import { createOperationLogService } from '../_shared/observability/operation-log-service.ts'
import { isInfrastructureBug } from '../_shared/observability/helpers.ts'

const FEATURE = 'signing-session-manager'

const DOCUSEAL_API_KEY = Deno.env.get('DOCUSEAL_API_KEY') ?? ''
const DOCUSEAL_API_URL = Deno.env.get('DOCUSEAL_API_URL') ?? 'https://api.docuseal.eu'

type Action = 'check' | 'cancel_local' | 'cancel_and_delete_remote' | 'generate_native_audit'

interface RequestBody {
  submission_id: string
  action: Action
  tenant_id?: string
}

class AppError extends Error {
  constructor(
    public readonly status: number,
    public readonly code: string,
    message: string,
  ) {
    super(message)
    this.name = 'AppError'
  }
}

function jsonOk(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}

function jsonError(status: number, code: string, message: string): Response {
  return new Response(JSON.stringify({ error: { code, message } }), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}

async function parseBody(req: Request): Promise<RequestBody> {
  let raw: Record<string, unknown>
  try {
    raw = await req.json()
  } catch {
    throw new AppError(400, 'invalid_json', 'Request body must be valid JSON')
  }

  if (typeof raw.submission_id !== 'string' || !raw.submission_id)
    throw new AppError(400, 'missing_submission_id', 'submission_id és obligatori')

  if (raw.action !== 'check' && raw.action !== 'cancel_local' && raw.action !== 'cancel_and_delete_remote' && raw.action !== 'generate_native_audit') {
    throw new AppError(400, 'invalid_action', 'action ha de ser check | cancel_local | cancel_and_delete_remote | generate_native_audit')
  }

  return {
    submission_id: raw.submission_id,
    action: raw.action,
    tenant_id: typeof raw.tenant_id === 'string' ? raw.tenant_id : undefined,
  }
}

async function resolveDocusealKey(
  adminClient: ReturnType<typeof createAdminClient>,
  userClient: ReturnType<typeof createUserClient>,
  tenantId: string,
): Promise<{ apiKey: string; apiUrl: string }> {
  const { data: cfg, error: cfgErr } = await adminClient
    .from('tenant_signing_status')
    .select('mode, docuseal_api_url')
    .eq('tenant_id', tenantId)
    .maybeSingle()

  if (cfgErr)
    log('warn', FEATURE, 'tenant_signing_status query error', { tenantId, extra: { error: cfgErr.message } })

  log('debug', FEATURE, 'resolveDocusealKey', {
    tenantId,
    extra: { cfg_mode: cfg?.mode ?? 'null', cfg_url: cfg?.docuseal_api_url ?? 'null' },
  })

  const apiUrl = (cfg?.docuseal_api_url as string | null) ?? DOCUSEAL_API_URL

  if (cfg?.mode === 'platform') {
    if (!DOCUSEAL_API_KEY)
      throw new AppError(500, 'platform_key_missing', 'DOCUSEAL_API_KEY no configurat a l\'entorn del servidor')
    log('debug', FEATURE, 'platform mode DocuSeal key resolved', {
      tenantId,
      extra: { key_length: DOCUSEAL_API_KEY.length, key_prefix: `${DOCUSEAL_API_KEY.slice(0, 4)}***`, url: apiUrl },
    })
    return { apiKey: DOCUSEAL_API_KEY, apiUrl }
  }

  if (!cfg) {
    // No hi ha configuració de signatura per a aquest tenant.
    // Fallback al mode platform (igual que sign-document-router faria throw,
    // però aquí preferim no bloquejar la cancel·lació per config absent).
    if (!DOCUSEAL_API_KEY)
      throw new AppError(500, 'platform_key_missing', 'DOCUSEAL_API_KEY no configurat a l\'entorn del servidor')
    log('warn', FEATURE, 'no tenant_signing_config, using platform key fallback', { tenantId })
    return { apiKey: DOCUSEAL_API_KEY, apiUrl }
  }

  // mode = byo → RPC per llegir de Vault
  const { data: key, error: rpcErr } = await userClient
    .rpc('get_docuseal_key_for_signing', { p_tenant_id: tenantId })

  if (rpcErr || !key)
    throw new AppError(500, 'byo_key_error', rpcErr?.message ?? 'No s\'ha pogut obtenir la clau DocuSeal BYO')

  const byoKey = key as string
  log('debug', FEATURE, 'byo mode DocuSeal key resolved', {
    tenantId,
    extra: { key_length: byoKey.length, key_prefix: `${byoKey.slice(0, 4)}***`, url: apiUrl },
  })
  return { apiKey: byoKey, apiUrl }
}

async function getDocusealSubmission(
  apiUrl: string,
  apiKey: string,
  docusealSubmissionId: string,
): Promise<{ found: boolean; payload: Record<string, unknown> | null }> {
  const res = await fetch(`${apiUrl}/submissions/${docusealSubmissionId}`, {
    method: 'GET',
    headers: {
      "X-Auth-Token":  apiKey,
      "Content-Type": "application/json",
    },
  })

  if (res.status === 404) return { found: false, payload: null }

  const bodyText = await res.text()
  if (!res.ok) {
    throw new AppError(502, 'docuseal_error', `DocuSeal GET /submissions/{id} ${res.status}: ${bodyText.slice(0, 500)}`)
  }

  try {
    return { found: true, payload: JSON.parse(bodyText) as Record<string, unknown> }
  } catch {
    return { found: true, payload: { raw: bodyText } }
  }
}

async function deleteDocusealSubmission(
  apiUrl: string,
  apiKey: string,
  docusealSubmissionId: string,
): Promise<{ found: boolean; deleted: boolean }> {
  const res = await fetch(`${apiUrl}/submissions/${docusealSubmissionId}`, {
    method: 'DELETE',
    headers: {
      "X-Auth-Token":  apiKey,
      "Content-Type": "application/json",
    },
  })

  if (res.status === 404) return { found: false, deleted: false }

  const bodyText = await res.text()
  if (!res.ok) {
    throw new AppError(502, 'docuseal_error', `DocuSeal DELETE /submissions/{id} ${res.status}: ${bodyText.slice(0, 500)}`)
  }

  return { found: true, deleted: true }
}

async function updateSubmissionCancelled(
  adminClient: ReturnType<typeof createAdminClient>,
  submissionId: string,
  tenantId: string,
  reason: string,
): Promise<void> {
  // Nota seguretat: adminClient bypassa RLS però l'autorització ja s'ha fet
  // via userClient (RLS) abans de cridar aquesta funció. El doble predicat
  // id + tenant_id actua com a defensa en profunditat.
  const { error } = await adminClient
    .from('signing_submissions')
    .update({
      status: 'cancelled',
      status_reason: reason,
      last_event_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    })
    .eq('id', submissionId)
    .eq('tenant_id', tenantId)

  if (error) throw new AppError(500, 'update_failed', error.message)
}

async function cancelNativeSigningSessions(
  adminClient: ReturnType<typeof createAdminClient>,
  tenantId: string,
  nativeGroupId: string | null,
): Promise<void> {
  if (!nativeGroupId) return

  const { error } = await adminClient
    .from('document_signing_sessions')
    .update({
      status:     'cancelled',
      updated_at: new Date().toISOString(),
    })
    .eq('tenant_id', tenantId)
    .eq('signing_group_id', nativeGroupId)
    .neq('status', 'signed')

  if (error) {
    log('warn', FEATURE, 'cancel native sessions failed', { extra: { error: error.message } })
  }
}

async function cleanupNativeSubmission(
  adminClient: ReturnType<typeof createAdminClient>,
  submission: {
    id: string
    tenant_id: string
    signing_provider?: string | null
    native_group_id?: string | null
    staging_storage_path?: string | null
  },
): Promise<void> {
  if (submission.signing_provider !== 'native') return

  await cancelNativeSigningSessions(
    adminClient,
    submission.tenant_id,
    submission.native_group_id ?? null,
  )

  await adminClient
    .from('signing_submissions')
    .update({
      staging_storage_path: null,
      updated_at: new Date().toISOString(),
    })
    .eq('id', submission.id)
    .eq('tenant_id', submission.tenant_id)

  await deleteStagingPdf(adminClient, submission.staging_storage_path)
}

async function insertAuditLogFireAndForget(
  adminClient: ReturnType<typeof createAdminClient>,
  tenantId: string,
  userId: string | null,
  action: string,
  submissionId: string,
  payload: Record<string, unknown>,
): Promise<void> {
  try {
    const { error } = await adminClient
      .from('audit_logs')
      .insert({
        tenant_id: tenantId,
        user_id: userId,
        action,
        entity_type: 'signing_submission',
        entity_id: submissionId,
        payload,
      })

    if (error) {
      log('warn', FEATURE, 'audit insert error', { extra: { error: error.message } })
    }
  } catch (err) {
    log('warn', FEATURE, 'audit insert failed', {
      extra: { error: err instanceof Error ? err.message : String(err) },
    })
  }
}

Deno.serve(async (req: Request) => {
  initObservability()

  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }
  if (req.method !== 'POST') {
    return jsonError(405, 'method_not_allowed', 'Només POST')
  }

  try {
    const body = await parseBody(req)

    const userClient = createUserClient(req)
    const { data: { user }, error: authError } = await userClient.auth.getUser()
    if (authError || !user) {
      return jsonError(401, 'unauthorized', 'Token invàlid o expirat')
    }

    // RLS check: només membres del tenant poden veure aquesta submissió.
    const { data: submission, error: submissionError } = await userClient
      .from('signing_submissions')
      .select('id, tenant_id, status, docuseal_submission_id, signing_provider, native_group_id, staging_storage_path, audit_trail_storage_path, result_document_version_id, document_title')
      .eq('id', body.submission_id)
      .maybeSingle()

    if (submissionError) {
      return jsonError(500, 'submission_lookup_failed', submissionError.message)
    }
    if (!submission) {
      return jsonError(404, 'submission_not_found', 'Submissió no trobada o sense permisos')
    }

    const headerTenantId = req.headers.get('x-tenant-id')
    if (headerTenantId && headerTenantId !== submission.tenant_id) {
      return jsonError(403, 'tenant_mismatch', 'x-tenant-id no coincideix amb el tenant de la submissió')
    }
    if (body.tenant_id && body.tenant_id !== submission.tenant_id) {
      return jsonError(403, 'tenant_mismatch', 'tenant_id no coincideix amb el tenant de la submissió')
    }

    const adminClient = createAdminClient()

    if (body.action === 'check') {
      if (!submission.docuseal_submission_id) {
        return jsonOk({
          action: body.action,
          submission_id: submission.id,
          tenant_id: submission.tenant_id,
          local_status: submission.status,
          docuseal_submission_id: null,
          remote_found: false,
          remote_submission: null,
          message: 'Aquesta submissió no té docuseal_submission_id. Probablement no es va arribar a enviar a DocuSeal.',
        })
      }

      const { apiKey, apiUrl } = await resolveDocusealKey(adminClient, userClient, submission.tenant_id)
      const remote = await getDocusealSubmission(apiUrl, apiKey, submission.docuseal_submission_id)

      return jsonOk({
        action: body.action,
        submission_id: submission.id,
        tenant_id: submission.tenant_id,
        local_status: submission.status,
        docuseal_submission_id: submission.docuseal_submission_id,
        remote_found: remote.found,
        remote_submission: remote.payload,
        message: remote.found
          ? 'Consulta de DocuSeal completada correctament.'
          : 'La submissió no existeix a DocuSeal (404).',
      })
    }

    if (body.action === 'cancel_local') {
      await cleanupNativeSubmission(adminClient, submission)
      await updateSubmissionCancelled(adminClient, submission.id, submission.tenant_id, 'cancelled_by_user')
      void insertAuditLogFireAndForget(
        adminClient,
        submission.tenant_id,
        user.id,
        'SIGNING_SESSION_CANCELLED',
        submission.id,
        {
          source: 'signing-session-manager',
          mode: 'local_only',
          previous_status: submission.status,
          docuseal_submission_id: submission.docuseal_submission_id,
        },
      )

      return jsonOk({
        action: body.action,
        submission_id: submission.id,
        tenant_id: submission.tenant_id,
        local_status: 'cancelled',
        docuseal_submission_id: submission.docuseal_submission_id,
        message: 'Sessió cancel·lada localment.',
      })
    }

    if (body.action === 'generate_native_audit') {
      if (submission.signing_provider !== 'native') {
        return jsonError(400, 'not_native', 'Només submissions de firma pròpia')
      }
      if (submission.status !== 'completed') {
        return jsonError(409, 'not_completed', 'La submission ha d\'estar completada')
      }
      if (!submission.native_group_id) {
        return jsonError(422, 'no_group', 'La submission no té native_group_id')
      }

      // Retornar el path si ja existeix
      if (submission.audit_trail_storage_path) {
        return jsonOk({
          action: body.action,
          submission_id: submission.id,
          tenant_id: submission.tenant_id,
          audit_storage_path: submission.audit_trail_storage_path,
          message: 'El certificat d\'auditoria ja existeix.',
        })
      }

      // Encuar job async + kick worker
      const { data: auditJobData, error: jobErr } = await adminClient.rpc('create_pdf_job', {
        p_tenant_id:       submission.tenant_id,
        p_source_type:     'document_existing',
        p_source_ref_id:   submission.result_document_version_id ?? null,
        p_template_type:   'html',
        p_document_title:  submission.document_title
          ? `Registre d'auditoria — ${submission.document_title}`
          : 'Registre d\'auditoria',
        p_output_profile:  'pdfa3b',
        p_idempotency_key: `audit-group-${submission.native_group_id}`,
        p_metadata:        {
          type:             'audit_certificate',
          signing_group_id: submission.native_group_id,
          submission_id:    submission.id,
        },
      })
      if (jobErr) {
        return jsonError(500, 'job_create_failed', jobErr.message)
      }

      const auditJob = auditJobData as { job_id: string } | null
      const jobId = auditJob?.job_id ?? null
      if (jobId) {
        const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
        const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
        kickPdfQueueWorker(SUPABASE_URL, SERVICE_ROLE_KEY)
      }

      return jsonOk({
        action: body.action,
        submission_id: submission.id,
        tenant_id: submission.tenant_id,
        audit_job_id: jobId,
        audit_storage_path: null,
        message: jobId
          ? 'Certificat d\'auditoria en procés. Actualitzeu en uns moments.'
          : 'No s\'ha pogut encuar el job d\'auditoria.',
      })
    }

    // cancel_and_delete_remote
    let remoteFound = false
    let remoteDeleted = false

    if (submission.docuseal_submission_id) {
      const { apiKey, apiUrl } = await resolveDocusealKey(adminClient, userClient, submission.tenant_id)
      const remoteResult = await deleteDocusealSubmission(apiUrl, apiKey, submission.docuseal_submission_id)
      remoteFound = remoteResult.found
      remoteDeleted = remoteResult.deleted
    }

    await cleanupNativeSubmission(adminClient, submission)
    await updateSubmissionCancelled(adminClient, submission.id, submission.tenant_id, remoteDeleted ? 'cancelled_remote_deleted' : 'cancelled_remote_missing')

    void insertAuditLogFireAndForget(
      adminClient,
      submission.tenant_id,
      user.id,
      'SIGNING_SESSION_REMOTE_DELETED',
      submission.id,
      {
        source: 'signing-session-manager',
        previous_status: submission.status,
        docuseal_submission_id: submission.docuseal_submission_id,
        remote_found: remoteFound,
        remote_deleted: remoteDeleted,
      },
    )

    return jsonOk({
      action: body.action,
      submission_id: submission.id,
      tenant_id: submission.tenant_id,
      local_status: 'cancelled',
      docuseal_submission_id: submission.docuseal_submission_id,
      remote_found: remoteFound,
      remote_deleted: remoteDeleted,
      message: remoteDeleted
        ? 'Sessió cancel·lada i eliminada a DocuSeal.'
        : (submission.docuseal_submission_id
            ? 'Sessió cancel·lada localment. A DocuSeal no s\'ha trobat la submissió.'
            : 'Sessió cancel·lada localment (sense docuseal_submission_id).'),
    })
  } catch (err) {
    if (err instanceof AppError) {
      return jsonError(err.status, err.code, err.message)
    }
    log('error', FEATURE, 'Unexpected error', {
      extra: { error: err instanceof Error ? err.message : String(err) },
    })
    captureException(err, { feature: FEATURE })
    return jsonError(500, 'internal_error', 'Error intern del servidor')
  }
})
