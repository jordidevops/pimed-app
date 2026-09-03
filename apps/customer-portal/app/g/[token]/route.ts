import { NextResponse } from 'next/server'
import { exchangeLoginToken } from '@/lib/resolver'
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
    title: 'Entrar al portal',
    body: 'Confirma per iniciar la sessió. Aquest pas evita que els filtres de correu consumeixin l’enllaç d’accés.',
  })
}

export async function POST(req: Request, { params }: Params) {
  const { token: raw } = await params
  const token = (raw ?? '').trim().toLowerCase()

  if (!HEX_64_RE.test(token)) {
    return NextResponse.redirect(new URL('/login?e=invalid', req.url), 303)
  }

  const result = await exchangeLoginToken(token)
  if (!result.ok || !result.session_token) {
    const res = NextResponse.redirect(new URL('/login?e=invalid', req.url), 303)
    clearSessionCookies(res)
    return res
  }

  const res = NextResponse.redirect(new URL('/dashboard', req.url), 303)
  setSessionCookies(res, result.session_token, 'grant', result.expires_at)
  return res
}
