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
    title: typeof json.title === 'string' ? json.title : undefined,
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

export type CommercialListItem = {
  item_kind: 'document' | 'agreement'
  id: string
  doc_type: string
  label: string
  status: string
  sort_date: string | null
  total: number | null
  currency: string | null
  valid_until: string | null
  agreement_kind: string | null
  project_label: string | null
  paid_total: number | null
  outstanding_total: number | null
  collection_status: string | null
}

export type PendingDecisionItem = {
  request_id: string
  purpose: string
  status: string
  expires_at: string | null
  created_at: string | null
  doc_type: string | null
  label: string | null
  formalization_mode: string | null
  total: number | null
  currency: string | null
  show_prices: boolean | null
  tenant_name: string | null
  expires_soon: boolean
}

export type PendingDecisionDetail = PendingDecisionItem & {
  active_provider?: string | null
  content_hash?: string | null
  has_pdf?: boolean
  /** Only when BFF requests include_pdf_url (PDF redirect). */
  pdf_url?: string | null
  decide_available?: boolean
  decline_available?: boolean
  accept_available?: boolean
  provider_continue_available?: boolean
  can_decide?: boolean
  decided_at?: string | null
  decided_via?: string | null
  account_name?: string | null
  snapshot?: {
    kind?: string | null
    doc_type?: string | null
    doc_number?: string | null
    formalization_mode?: string | null
    total?: number | null
    currency?: string | null
    locale?: string | null
    valid_until?: string | null
    show_prices?: boolean | null
    purpose?: string | null
  } | null
  tenant?: {
    name?: string | null
    logo_url?: string | null
  } | null
  receipt?: {
    outcome?: string | null
    decided_at?: string | null
    decided_via?: string | null
    signer_name?: string | null
    reason?: string | null
    trace_id?: string | null
  } | null
}

export type CommercialLine = {
  position: number | null
  name: string | null
  description: string | null
  unit: string | null
  quantity: number | null
  unit_price: number | null
  discount_pct: number | null
  tax_rate: number | null
  line_subtotal: number | null
  line_tax: number | null
  line_total: number | null
}

export type CommercialDetail = CommercialListItem & {
  show_prices?: boolean | null
  subtotal?: number | null
  starts_on?: string | null
  ends_on?: string | null
  version_no?: number | null
  agreement_status?: string | null
  source_quote_label?: string | null
  linked_invoice_label?: string | null
  has_pdf?: boolean
  /** Only present when BFF requests include_pdf_url (PDF redirect route). */
  pdf_url?: string | null
  decision?: {
    status?: string
    decided_at?: string | null
    decided_via?: string | null
  } | null
  lines?: CommercialLine[]
  source_delivery_notes?: Array<{
    id: string
    label: string | null
    status: string | null
  }>
  payments?: Array<{
    occurred_at: string | null
    amount: number | null
    reference_masked: string | null
  }>
}

export type CommercialResolveOk = {
  ok: true
  action?: string
  kind?: string
  grant_id?: string
  tenant_id?: string
  client_account_contact_id?: string
  modules?: {
    quotes_agreements?: boolean
    delivery_notes?: boolean
    invoices?: boolean
  }
  pending_decisions_count?: number
  principal_kind?: string | null
  items: CommercialListItem[]
  pending_items?: PendingDecisionItem[]
  detail?: CommercialDetail
  pending_detail?: PendingDecisionDetail
}

function parsePendingItem(raw: unknown): PendingDecisionItem | null {
  if (!raw || typeof raw !== 'object') return null
  const o = raw as Record<string, unknown>
  const request_id = typeof o.request_id === 'string' ? o.request_id : ''
  if (!request_id) return null
  return {
    request_id,
    purpose: typeof o.purpose === 'string' ? o.purpose : '',
    status: typeof o.status === 'string' ? o.status : '',
    expires_at: typeof o.expires_at === 'string' ? o.expires_at : null,
    created_at: typeof o.created_at === 'string' ? o.created_at : null,
    doc_type: typeof o.doc_type === 'string' ? o.doc_type : null,
    label: typeof o.label === 'string' ? o.label : null,
    formalization_mode:
      typeof o.formalization_mode === 'string' ? o.formalization_mode : null,
    total: typeof o.total === 'number' ? o.total : null,
    currency: typeof o.currency === 'string' ? o.currency : null,
    show_prices: typeof o.show_prices === 'boolean' ? o.show_prices : null,
    tenant_name: typeof o.tenant_name === 'string' ? o.tenant_name : null,
    expires_soon: o.expires_soon === true,
  }
}

function parsePendingDetail(raw: unknown): PendingDecisionDetail | undefined {
  const base = parsePendingItem(raw)
  if (!base || !raw || typeof raw !== 'object') return undefined
  const o = raw as Record<string, unknown>
  const snap =
    o.snapshot && typeof o.snapshot === 'object'
      ? (o.snapshot as Record<string, unknown>)
      : null
  const tenant =
    o.tenant && typeof o.tenant === 'object'
      ? (o.tenant as Record<string, unknown>)
      : null
  const receiptRaw =
    o.receipt && typeof o.receipt === 'object'
      ? (o.receipt as Record<string, unknown>)
      : null

  return {
    ...base,
    active_provider:
      typeof o.active_provider === 'string' ? o.active_provider : null,
    content_hash: typeof o.content_hash === 'string' ? o.content_hash : null,
    has_pdf: o.has_pdf === true,
    pdf_url: typeof o.pdf_url === 'string' ? o.pdf_url : null,
    decide_available: o.decide_available === true,
    decline_available: o.decline_available === true,
    accept_available: o.accept_available === true,
    provider_continue_available: o.provider_continue_available === true,
    can_decide: o.can_decide === true,
    decided_at: typeof o.decided_at === 'string' ? o.decided_at : null,
    decided_via: typeof o.decided_via === 'string' ? o.decided_via : null,
    account_name: typeof o.account_name === 'string' ? o.account_name : null,
    snapshot: snap
      ? {
          kind: typeof snap.kind === 'string' ? snap.kind : null,
          doc_type: typeof snap.doc_type === 'string' ? snap.doc_type : null,
          doc_number:
            typeof snap.doc_number === 'string' ? snap.doc_number : null,
          formalization_mode:
            typeof snap.formalization_mode === 'string'
              ? snap.formalization_mode
              : null,
          total: typeof snap.total === 'number' ? snap.total : null,
          currency: typeof snap.currency === 'string' ? snap.currency : null,
          locale: typeof snap.locale === 'string' ? snap.locale : null,
          valid_until:
            typeof snap.valid_until === 'string' ? snap.valid_until : null,
          show_prices:
            typeof snap.show_prices === 'boolean' ? snap.show_prices : null,
          purpose: typeof snap.purpose === 'string' ? snap.purpose : null,
        }
      : null,
    tenant: tenant
      ? {
          name: typeof tenant.name === 'string' ? tenant.name : null,
          logo_url: typeof tenant.logo_url === 'string' ? tenant.logo_url : null,
        }
      : null,
    receipt: receiptRaw
      ? {
          outcome:
            typeof receiptRaw.outcome === 'string' ? receiptRaw.outcome : null,
          decided_at:
            typeof receiptRaw.decided_at === 'string'
              ? receiptRaw.decided_at
              : null,
          decided_via:
            typeof receiptRaw.decided_via === 'string'
              ? receiptRaw.decided_via
              : null,
          signer_name:
            typeof receiptRaw.signer_name === 'string'
              ? receiptRaw.signer_name
              : null,
          reason:
            typeof receiptRaw.reason === 'string' ? receiptRaw.reason : null,
          trace_id:
            typeof receiptRaw.trace_id === 'string'
              ? receiptRaw.trace_id
              : null,
        }
      : null,
  }
}

function parseCommercialDetail(raw: unknown): CommercialDetail | undefined {
  if (!raw || typeof raw !== 'object') return undefined
  const o = raw as Record<string, unknown>
  const id = typeof o.id === 'string' ? o.id : ''
  if (!id) return undefined

  const linesRaw = Array.isArray(o.lines) ? o.lines : []
  const lines: CommercialLine[] = []
  for (const line of linesRaw) {
    if (!line || typeof line !== 'object') continue
    const l = line as Record<string, unknown>
    lines.push({
      position: typeof l.position === 'number' ? l.position : null,
      name: typeof l.name === 'string' ? l.name : null,
      description: typeof l.description === 'string' ? l.description : null,
      unit: typeof l.unit === 'string' ? l.unit : null,
      quantity: typeof l.quantity === 'number' ? l.quantity : null,
      unit_price: typeof l.unit_price === 'number' ? l.unit_price : null,
      discount_pct: typeof l.discount_pct === 'number' ? l.discount_pct : null,
      tax_rate: typeof l.tax_rate === 'number' ? l.tax_rate : null,
      line_subtotal: typeof l.line_subtotal === 'number' ? l.line_subtotal : null,
      line_tax: typeof l.line_tax === 'number' ? l.line_tax : null,
      line_total: typeof l.line_total === 'number' ? l.line_total : null,
    })
  }

  const decision =
    o.decision && typeof o.decision === 'object'
      ? (o.decision as CommercialDetail['decision'])
      : null

  const dnsRaw = Array.isArray(o.source_delivery_notes)
    ? o.source_delivery_notes
    : []
  const source_delivery_notes = dnsRaw
    .filter((x): x is Record<string, unknown> => !!x && typeof x === 'object')
    .map((x) => ({
      id: typeof x.id === 'string' ? x.id : '',
      label: typeof x.label === 'string' ? x.label : null,
      status: typeof x.status === 'string' ? x.status : null,
    }))
    .filter((x) => x.id)

  const payRaw = Array.isArray(o.payments) ? o.payments : []
  const payments = payRaw
    .filter((x): x is Record<string, unknown> => !!x && typeof x === 'object')
    .map((x) => ({
      occurred_at: typeof x.occurred_at === 'string' ? x.occurred_at : null,
      amount: typeof x.amount === 'number' ? x.amount : null,
      reference_masked:
        typeof x.reference_masked === 'string' ? x.reference_masked : null,
    }))

  return {
    item_kind: o.item_kind === 'agreement' ? 'agreement' : 'document',
    id,
    doc_type: typeof o.doc_type === 'string' ? o.doc_type : '',
    label: typeof o.label === 'string' ? o.label : '',
    status: typeof o.status === 'string' ? o.status : '',
    sort_date: typeof o.sort_date === 'string' ? o.sort_date : null,
    total: typeof o.total === 'number' ? o.total : null,
    currency: typeof o.currency === 'string' ? o.currency : null,
    valid_until: typeof o.valid_until === 'string' ? o.valid_until : null,
    agreement_kind:
      typeof o.agreement_kind === 'string' ? o.agreement_kind : null,
    project_label: typeof o.project_label === 'string' ? o.project_label : null,
    paid_total: typeof o.paid_total === 'number' ? o.paid_total : null,
    outstanding_total:
      typeof o.outstanding_total === 'number' ? o.outstanding_total : null,
    collection_status:
      typeof o.collection_status === 'string' ? o.collection_status : null,
    show_prices: typeof o.show_prices === 'boolean' ? o.show_prices : null,
    subtotal: typeof o.subtotal === 'number' ? o.subtotal : null,
    starts_on: typeof o.starts_on === 'string' ? o.starts_on : null,
    ends_on: typeof o.ends_on === 'string' ? o.ends_on : null,
    version_no: typeof o.version_no === 'number' ? o.version_no : null,
    agreement_status:
      typeof o.agreement_status === 'string' ? o.agreement_status : null,
    source_quote_label:
      typeof o.source_quote_label === 'string' ? o.source_quote_label : null,
    linked_invoice_label:
      typeof o.linked_invoice_label === 'string'
        ? o.linked_invoice_label
        : null,
    has_pdf: o.has_pdf === true,
    pdf_url: typeof o.pdf_url === 'string' ? o.pdf_url : null,
    decision,
    lines,
    source_delivery_notes,
    payments,
  }
}

export async function resolveCommercialSession(params: {
  sessionToken: string
  action?:
    | 'list_documents'
    | 'list_summary'
    | 'get_quote_or_agreement'
    | 'get_delivery_note'
    | 'get_invoice'
    | 'list_pending_decisions'
    | 'get_pending_decision'
    | 'decline_pending_decision'
  kind?: 'quotes_agreements' | 'delivery_notes' | 'invoices'
  cursorSort?: string | null
  cursorId?: string | null
  limit?: number
  targetId?: string | null
  itemKind?: 'document' | 'agreement' | null
  /** Server-only: mint signed PDF URL (PDF BFF redirect). Never use from SSR pages. */
  includePdfUrl?: boolean
}): Promise<CommercialResolveOk | ResolveFail> {
  if (!HEX_64_RE.test(params.sessionToken)) {
    return { ok: false, error: 'not_found', status: 404 }
  }

  const body: Record<string, unknown> = {
    session_token: params.sessionToken,
    action: params.action ?? 'list_documents',
    kind: params.kind ?? 'quotes_agreements',
    cursor_sort: params.cursorSort ?? null,
    cursor_id: params.cursorId ?? null,
    limit: params.limit ?? 20,
    target_id: params.targetId ?? null,
    item_kind: params.itemKind ?? null,
  }
  if (params.includePdfUrl === true) {
    body.include_pdf_url = true
  }

  const res = await fetch(
    `${edgeBaseUrl()}/functions/v1/resolve-customer-portal-commercial`,
    {
      method: 'POST',
      headers: authHeaders(),
      body: JSON.stringify(body),
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
      error: typeof json.error === 'string' ? json.error : 'not_found',
      status: res.status,
    }
  }

  const action =
    typeof json.action === 'string' ? json.action : undefined
  const rawItems = Array.isArray(json.items) ? json.items : []
  const items: CommercialListItem[] = []
  const pending_items: PendingDecisionItem[] = []

  if (action === 'list_pending_decisions') {
    for (const raw of rawItems) {
      const item = parsePendingItem(raw)
      if (item) pending_items.push(item)
    }
  } else {
    for (const raw of rawItems) {
      if (!raw || typeof raw !== 'object') continue
      const o = raw as Record<string, unknown>
      const id = typeof o.id === 'string' ? o.id : ''
      if (!id) continue
      items.push({
        item_kind: o.item_kind === 'agreement' ? 'agreement' : 'document',
        id,
        doc_type: typeof o.doc_type === 'string' ? o.doc_type : '',
        label: typeof o.label === 'string' ? o.label : '',
        status: typeof o.status === 'string' ? o.status : '',
        sort_date: typeof o.sort_date === 'string' ? o.sort_date : null,
        total: typeof o.total === 'number' ? o.total : null,
        currency: typeof o.currency === 'string' ? o.currency : null,
        valid_until: typeof o.valid_until === 'string' ? o.valid_until : null,
        agreement_kind:
          typeof o.agreement_kind === 'string' ? o.agreement_kind : null,
        project_label:
          typeof o.project_label === 'string' ? o.project_label : null,
        paid_total: typeof o.paid_total === 'number' ? o.paid_total : null,
        outstanding_total:
          typeof o.outstanding_total === 'number' ? o.outstanding_total : null,
        collection_status:
          typeof o.collection_status === 'string' ? o.collection_status : null,
      })
    }
  }

  const modules =
    json.modules && typeof json.modules === 'object'
      ? (json.modules as CommercialResolveOk['modules'])
      : undefined

  const pendingDetail =
    action === 'get_pending_decision'
      ? parsePendingDetail(json.detail)
      : undefined

  return {
    ok: true,
    action,
    kind: typeof json.kind === 'string' ? json.kind : undefined,
    grant_id: typeof json.grant_id === 'string' ? json.grant_id : undefined,
    tenant_id: typeof json.tenant_id === 'string' ? json.tenant_id : undefined,
    client_account_contact_id:
      typeof json.client_account_contact_id === 'string'
        ? json.client_account_contact_id
        : undefined,
    modules,
    pending_decisions_count:
      typeof json.pending_decisions_count === 'number'
        ? json.pending_decisions_count
        : undefined,
    principal_kind:
      typeof json.principal_kind === 'string' ? json.principal_kind : null,
    items,
    pending_items: action === 'list_pending_decisions' ? pending_items : undefined,
    detail:
      action === 'get_pending_decision'
        ? undefined
        : parseCommercialDetail(json.detail),
    pending_detail: pendingDetail,
  }
}

export async function resolvePendingDecisionDetail(params: {
  sessionToken: string
  requestId: string
}): Promise<
  | (CommercialResolveOk & { pending_detail: PendingDecisionDetail })
  | ResolveFail
> {
  const result = await resolveCommercialSession({
    sessionToken: params.sessionToken,
    action: 'get_pending_decision',
    targetId: params.requestId,
  })
  if (!result.ok) return result
  if (!result.pending_detail) {
    return { ok: false, error: 'not_found', status: 404 }
  }
  return { ...result, pending_detail: result.pending_detail }
}

export type DeclinePendingResult = {
  ok: true
  request_id?: string
  status?: string
  applied?: boolean
  already_decided?: boolean
  decided_via?: string | null
  decided_at?: string | null
}

export async function acceptPendingDecision(params: {
  sessionToken: string
  requestId: string
  signatureBase64: string
  actorName?: string | null
  actorRole?: string | null
}): Promise<DeclinePendingResult | ResolveFail> {
  if (!HEX_64_RE.test(params.sessionToken)) {
    return { ok: false, error: 'not_found', status: 404 }
  }

  const res = await fetch(
    `${edgeBaseUrl()}/functions/v1/resolve-customer-portal-commercial`,
    {
      method: 'POST',
      headers: authHeaders(),
      body: JSON.stringify({
        session_token: params.sessionToken,
        action: 'accept_pending_decision',
        target_id: params.requestId,
        signature_base64: params.signatureBase64,
        actor_name: params.actorName ?? null,
        actor_role: params.actorRole ?? null,
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
      error: typeof json.error === 'string' ? json.error : 'not_found',
      status: res.status,
    }
  }

  const result =
    json.result && typeof json.result === 'object'
      ? (json.result as Record<string, unknown>)
      : {}

  return {
    ok: true,
    request_id: typeof result.request_id === 'string' ? result.request_id : undefined,
    status: typeof result.status === 'string' ? result.status : undefined,
    applied: result.applied === true,
    already_decided: result.already_decided === true,
    decided_via:
      typeof result.decided_via === 'string' ? result.decided_via : null,
    decided_at:
      typeof result.decided_at === 'string' ? result.decided_at : null,
  }
}

export type ContinueDocusealResult =
  | {
      ok: true
      request_id?: string
      redirect_url: string
      already_decided?: boolean
      status?: string
      decided_via?: string | null
      decided_at?: string | null
    }
  | ResolveFail

export async function continuePendingDocuseal(params: {
  sessionToken: string
  requestId: string
}): Promise<ContinueDocusealResult> {
  if (!HEX_64_RE.test(params.sessionToken)) {
    return { ok: false, error: 'not_found', status: 404 }
  }

  const res = await fetch(
    `${edgeBaseUrl()}/functions/v1/resolve-customer-portal-commercial`,
    {
      method: 'POST',
      headers: authHeaders(),
      body: JSON.stringify({
        session_token: params.sessionToken,
        action: 'bridge_docuseal_pending_decision',
        target_id: params.requestId,
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
      error: typeof json.error === 'string' ? json.error : 'not_found',
      status: res.status,
    }
  }

  const result =
    json.result && typeof json.result === 'object'
      ? (json.result as Record<string, unknown>)
      : {}

  if (result.already_decided === true) {
    return {
      ok: true,
      request_id:
        typeof result.request_id === 'string' ? result.request_id : undefined,
      redirect_url: '',
      already_decided: true,
      status: typeof result.status === 'string' ? result.status : undefined,
      decided_via:
        typeof result.decided_via === 'string' ? result.decided_via : null,
      decided_at:
        typeof result.decided_at === 'string' ? result.decided_at : null,
    }
  }

  const redirectUrl =
    typeof result.redirect_url === 'string' ? result.redirect_url.trim() : ''
  if (!redirectUrl) {
    return { ok: false, error: 'provider_pending', status: 409 }
  }

  return {
    ok: true,
    request_id:
      typeof result.request_id === 'string' ? result.request_id : undefined,
    redirect_url: redirectUrl,
  }
}

export async function declinePendingDecision(params: {
  sessionToken: string
  requestId: string
  reason?: string | null
  actorName?: string | null
  actorRole?: string | null
  clientOpId?: string
}): Promise<DeclinePendingResult | ResolveFail> {
  if (!HEX_64_RE.test(params.sessionToken)) {
    return { ok: false, error: 'not_found', status: 404 }
  }

  const res = await fetch(
    `${edgeBaseUrl()}/functions/v1/resolve-customer-portal-commercial`,
    {
      method: 'POST',
      headers: authHeaders(),
      body: JSON.stringify({
        session_token: params.sessionToken,
        action: 'decline_pending_decision',
        target_id: params.requestId,
        reason: params.reason ?? null,
        actor_name: params.actorName ?? null,
        actor_role: params.actorRole ?? null,
        client_op_id: params.clientOpId ?? crypto.randomUUID(),
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
      error: typeof json.error === 'string' ? json.error : 'not_found',
      status: res.status,
    }
  }

  const result =
    json.result && typeof json.result === 'object'
      ? (json.result as Record<string, unknown>)
      : {}

  return {
    ok: true,
    request_id: typeof result.request_id === 'string' ? result.request_id : undefined,
    status: typeof result.status === 'string' ? result.status : undefined,
    applied: result.applied === true,
    already_decided: result.already_decided === true,
    decided_via:
      typeof result.decided_via === 'string' ? result.decided_via : null,
    decided_at:
      typeof result.decided_at === 'string' ? result.decided_at : null,
  }
}

export async function resolveCommercialDetail(params: {
  sessionToken: string
  action: 'get_quote_or_agreement' | 'get_delivery_note' | 'get_invoice'
  targetId: string
  itemKind?: 'document' | 'agreement'
}): Promise<
  | (CommercialResolveOk & { detail: CommercialDetail })
  | ResolveFail
> {
  const result = await resolveCommercialSession({
    sessionToken: params.sessionToken,
    action: params.action,
    targetId: params.targetId,
    itemKind: params.itemKind ?? null,
  })
  if (!result.ok) return result
  if (!result.detail) {
    return { ok: false, error: 'not_found', status: 404 }
  }
  return { ...result, detail: result.detail }
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
