import { NextResponse } from 'next/server'
import { exchangeStaffToken } from '@/lib/resolver'
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
    invalidRedirect: '/?e=invalid',
    title: 'Vista de suport',
    body: 'Confirma per obrir la vista de suport. L’enllaç és d’un sol ús; després la sessió queda al navegador.',
    buttonLabel: 'Obrir vista',
  })
}

export async function POST(req: Request, { params }: Params) {
  const { token: raw } = await params
  const token = (raw ?? '').trim().toLowerCase()

  if (!HEX_64_RE.test(token)) {
    return NextResponse.redirect(new URL('/?e=invalid', req.url), 303)
  }

  const result = await exchangeStaffToken(token)
  if (!result.ok || !result.session_token) {
    const res = NextResponse.redirect(new URL('/?e=invalid', req.url), 303)
    clearSessionCookies(res)
    return res
  }

  // Cookie must be the rotated opaque secret — never the URL handoff.
  const res = NextResponse.redirect(new URL('/r', req.url), 303)
  setSessionCookies(res, result.session_token, 'staff', result.expires_at)
  return res
}
