import { NextResponse } from 'next/server'
import { clearSessionCookies } from '@/lib/session'

export async function GET(req: Request) {
  const res = NextResponse.redirect(new URL('/login', req.url), 303)
  clearSessionCookies(res)
  return res
}
