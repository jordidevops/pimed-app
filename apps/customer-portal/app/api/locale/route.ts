import { NextResponse } from 'next/server'
import {
  resolveGrantSession,
  resolveShareSession,
  setCustomerPortalAccountLocale,
} from '@/lib/resolver'
import { isPlatformLocale } from '@/lib/locale'
import {
  readActorCookie,
  readSessionCookie,
  setUiLocaleCookie,
} from '@/lib/session'

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

export async function POST(req: Request) {
  const session = await readSessionCookie()
  const actor = await readActorCookie()
  // Staff handoff must not change account preferred_locale (plan).
  // Share + grant may persist when allow_client_locale_change.
  if (!session || (actor !== 'grant' && actor !== 'share')) {
    return NextResponse.json({ error: 'unauthorized' }, { status: 401 })
  }

  let body: {
    locale?: string
    account_contact_id?: string
    tenant_id?: string
  }
  try {
    body = await req.json()
  } catch {
    return NextResponse.json({ error: 'invalid_body' }, { status: 400 })
  }

  const locale =
    typeof body.locale === 'string' ? body.locale.trim().toLowerCase() : ''
  const accountContactId =
    typeof body.account_contact_id === 'string'
      ? body.account_contact_id.trim()
      : ''
  const tenantId =
    typeof body.tenant_id === 'string' ? body.tenant_id.trim() : ''

  if (!isPlatformLocale(locale)) {
    return NextResponse.json({ error: 'invalid_locale' }, { status: 400 })
  }
  if (!UUID_RE.test(accountContactId) || !UUID_RE.test(tenantId)) {
    return NextResponse.json({ error: 'invalid_ids' }, { status: 400 })
  }

  let resolvedTenant: string | undefined
  let resolvedAccount: string | undefined
  let allowChange = false

  if (actor === 'grant') {
    const result = await resolveGrantSession(session, 'list_bulletins')
    if (!result.ok) {
      return NextResponse.json({ error: 'unauthorized' }, { status: 401 })
    }
    resolvedTenant = result.tenant_id
    resolvedAccount = result.client_account_contact_id
    allowChange = result.allow_client_locale_change === true
  } else {
    const result = await resolveShareSession(session, 'report_view')
    if (!result.ok) {
      return NextResponse.json({ error: 'unauthorized' }, { status: 401 })
    }
    resolvedTenant = result.tenant_id
    resolvedAccount = result.client_account_contact_id
    allowChange = result.allow_client_locale_change === true
  }

  if (!allowChange) {
    return NextResponse.json(
      { error: 'client_locale_change_not_allowed' },
      { status: 403 },
    )
  }

  if (
    !resolvedTenant ||
    !resolvedAccount ||
    resolvedTenant !== tenantId ||
    resolvedAccount !== accountContactId
  ) {
    return NextResponse.json({ error: 'forbidden' }, { status: 403 })
  }

  const edge = await setCustomerPortalAccountLocale({
    locale,
    accountContactId,
    tenantId,
  })
  if (!edge.ok) {
    return NextResponse.json(
      { error: edge.error },
      { status: edge.status >= 400 ? edge.status : 502 },
    )
  }

  const res = NextResponse.json({ ok: true, locale })
  setUiLocaleCookie(res, locale)
  return res
}
