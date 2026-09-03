import { NextResponse } from 'next/server'
import { exchangeInvitationToken } from '@/lib/resolver'
import { clearSessionCookies, setSessionCookies } from '@/lib/session'
import { HEX_64_RE } from '@/lib/constants'
import { sterileConfirmGet, sterileHead } from '@/lib/confirm'

type Params = { params: Promise<{ token: string }> }

export async function HEAD() {
  return sterileHead()
}

export async function GET(req: Request, { params }: Params) {
  const { token } = await params
  return sterileConfirmGet(req, token, {
    invalidRedirect: '/login?e=invalid',
    title: 'Acceptar invitació',
    body: 'Confirma per activar l’accés al portal. Aquest pas evita que els filtres de correu consumeixin la invitació.',
  })
}

export async function POST(req: Request, { params }: Params) {
  const { token: raw } = await params
  const token = (raw ?? '').trim().toLowerCase()

  if (!HEX_64_RE.test(token)) {
    return NextResponse.redirect(new URL('/login?e=invalid', req.url), 303)
  }

  // Accept + auth user creation only on POST (never on SafeLinks GET).
  const result = await exchangeInvitationToken(token)
  if (!result.ok || !result.session_token) {
    const res = NextResponse.redirect(new URL('/login?e=invalid', req.url), 303)
    clearSessionCookies(res)
    return res
  }

  const res = NextResponse.redirect(new URL('/dashboard', req.url), 303)
  setSessionCookies(res, result.session_token, 'grant', result.expires_at)
  return res
}
