import { HEX_64_RE, type ResolveFail, type ResolveOk } from './constants'

function edgeBaseUrl(): string {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL
  if (!url) throw new Error('NEXT_PUBLIC_SUPABASE_URL missing')
  return url.replace(/\/$/, '')
}

function gatewayKey(): string {
  const key = process.env.SUPABASE_PUBLISHABLE_KEY
  if (!key) throw new Error('SUPABASE_PUBLISHABLE_KEY missing')
  return key
}

function authHeaders(): HeadersInit {
  const key = gatewayKey()
  const bffSecret = process.env.CUSTOMER_PORTAL_BFF_SECRET
  if (!bffSecret) throw new Error('CUSTOMER_PORTAL_BFF_SECRET missing')
  return {
    'Content-Type': 'application/json',
    Authorization: `Bearer ${key}`,
    apikey: key,
    'X-Customer-Portal-Bff-Secret': bffSecret,
  }
}

function parseResolverJson(
  res: Response,
  json: Record<string, unknown>,
  actorFallback: 'share' | 'staff' | 'grant',
): ResolveOk | ResolveFail {
  if (!res.ok) {
    return {
      ok: false,
      error: typeof json.error === 'string' ? json.error : 'not_found',
      status: res.status,
    }
  }

  const rawActor = json.actor_type
  const actor_type: ResolveOk['actor_type'] =
    rawActor === 'staff' || rawActor === 'grant' || rawActor === 'share'
      ? rawActor
      : actorFallback

  const supportedRaw = json.supported_locales
  const supported_locales = Array.isArray(supportedRaw)
    ? supportedRaw.filter((x): x is string => typeof x === 'string')
    : undefined

  return {
    ok: true,
    session_token: json.session_token as string | undefined,
    expires_at: json.expires_at as string | undefined,
    locale: json.locale as string | undefined,
    content_digest: json.content_digest as string | undefined,
    projection: (json.projection as Record<string, unknown>) ?? undefined,
    media_manifest: json.media_manifest,
    actor_type,
    staff_user_id: json.staff_user_id as string | undefined,
    bulletins: json.bulletins,
    report_version_id: json.report_version_id as string | undefined,
    grant_id: json.grant_id as string | undefined,
    tenant_id: json.tenant_id as string | undefined,
    scope_mode: json.scope_mode as ResolveOk['scope_mode'],
    client_account_contact_id: json.client_account_contact_id as string | undefined,
    requires_report_version_id: Boolean(json.requires_report_version_id),
    preferred_locale:
      typeof json.preferred_locale === 'string' ? json.preferred_locale : null,
    supported_locales,
    default_locale:
      typeof json.default_locale === 'string' ? json.default_locale : null,
    allow_client_locale_change: json.allow_client_locale_change === true,
    content_locale:
      typeof json.content_locale === 'string' ? json.content_locale : null,
    access_activity:
      json.access_activity && typeof json.access_activity === 'object'
        ? (json.access_activity as ResolveOk['access_activity'])
        : undefined,
    tenant_profile:
      json.tenant_profile && typeof json.tenant_profile === 'object'
        ? (json.tenant_profile as ResolveOk['tenant_profile'])
        : undefined,
  }
}

async function callResolver(
  body: Record<string, unknown>,
): Promise<ResolveOk | ResolveFail> {
  const res = await fetch(`${edgeBaseUrl()}/functions/v1/resolve-customer-report-share`, {
    method: 'POST',
    headers: authHeaders(),
    body: JSON.stringify(body),
    cache: 'no-store',
  })

  let json: Record<string, unknown> = {}
  try {
    json = (await res.json()) as Record<string, unknown>
  } catch {
    json = {}
  }

  return parseResolverJson(res, json, 'share')
}

async function callGrantResolver(
  body: Record<string, unknown>,
): Promise<ResolveOk | ResolveFail> {
  const res = await fetch(`${edgeBaseUrl()}/functions/v1/resolve-customer-portal-grant`, {
    method: 'POST',
    headers: authHeaders(),
    body: JSON.stringify(body),
    cache: 'no-store',
  })

  let json: Record<string, unknown> = {}
  try {
    json = (await res.json()) as Record<string, unknown>
  } catch {
    json = {}
  }

  return parseResolverJson(res, json, 'grant')
}

export async function exchangeShareToken(token: string): Promise<ResolveOk | ResolveFail> {
  if (!HEX_64_RE.test(token)) {
    return { ok: false, error: 'not_found', status: 404 }
  }
  return callResolver({ token })
}

export async function resolveShareSession(
  sessionToken: string,
  action = 'report_view',
  _requestId?: string,
): Promise<ResolveOk | ResolveFail> {
  if (!HEX_64_RE.test(sessionToken)) {
    return { ok: false, error: 'not_found', status: 404 }
  }
  return callResolver({
    session_token: sessionToken,
    action,
    // Audit idempotency must never trust a client-supplied id.
    request_id: crypto.randomUUID(),
  })
}

export async function exchangeStaffToken(
  token: string,
  reportVersionId?: string,
): Promise<ResolveOk | ResolveFail> {
  if (!HEX_64_RE.test(token)) {
    return { ok: false, error: 'not_found', status: 404 }
  }
  const body: Record<string, unknown> = { staff_token: token }
  if (reportVersionId) {
    body.report_version_id = reportVersionId
  }
  return callResolver(body)
}

export async function exchangeInvitationToken(
  token: string,
): Promise<ResolveOk | ResolveFail> {
  if (!HEX_64_RE.test(token)) {
    return { ok: false, error: 'not_found', status: 404 }
  }
  return callGrantResolver({ invitation_token: token })
}

export async function exchangeLoginToken(token: string): Promise<ResolveOk | ResolveFail> {
  if (!HEX_64_RE.test(token)) {
    return { ok: false, error: 'not_found', status: 404 }
  }
  return callGrantResolver({ login_token: token })
}

export async function requestLoginEmail(
  email: string,
): Promise<{ ok: true } | ResolveFail> {
  const res = await callGrantResolver({
    login_email: email,
  })
  if (!res.ok) return res
  return { ok: true }
}

export async function resolveGrantSession(
  sessionToken: string,
  action: 'list_bulletins' | 'report_view' | 'media_download' = 'list_bulletins',
  reportVersionId?: string,
  _requestId?: string,
): Promise<ResolveOk | ResolveFail> {
  if (!HEX_64_RE.test(sessionToken)) {
    return { ok: false, error: 'not_found', status: 404 }
  }
  return callGrantResolver({
    session_token: sessionToken,
    action,
    report_version_id: reportVersionId,
    request_id: crypto.randomUUID(),
  })
}

export async function streamReportMedia(params: {
  actorType: 'share' | 'staff' | 'grant'
  sessionToken: string
  objectKey: string
  reportVersionId?: string
  range?: string
  requestId?: string
  userAgent?: string
}): Promise<Response> {
  const headers = new Headers(authHeaders())
  if (params.range) headers.set('Range', params.range)
  if (params.userAgent) headers.set('User-Agent', params.userAgent)

  return fetch(`${edgeBaseUrl()}/functions/v1/stream-customer-report-media`, {
    method: 'POST',
    headers,
    body: JSON.stringify({
      actor_type: params.actorType,
      session_token: params.sessionToken,
      object_key: params.objectKey,
      report_version_id: params.reportVersionId,
      request_id: params.requestId ?? crypto.randomUUID(),
    }),
    cache: 'no-store',
  })
}

export async function setCustomerPortalAccountLocale(params: {
  locale: string
  accountContactId: string
  tenantId: string
}): Promise<{ ok: true } | ResolveFail> {
  const res = await fetch(
    `${edgeBaseUrl()}/functions/v1/set-customer-portal-locale`,
    {
      method: 'POST',
      headers: authHeaders(),
      body: JSON.stringify({
        locale: params.locale,
        account_contact_id: params.accountContactId,
        tenant_id: params.tenantId,
      }),
      cache: 'no-store',
    },
  )

  let json: Record<string, unknown> = {}
  try {
    json = (await res.json()) as Record<string, unknown>
  } catch {
    json = {}
  }

  if (!res.ok) {
    return {
      ok: false,
      error: typeof json.error === 'string' ? json.error : 'failed',
      status: res.status,
    }
  }
  return { ok: true }
}
