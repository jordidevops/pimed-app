import { cookies } from 'next/headers'
import { NextResponse } from 'next/server'
import {
  ACTOR_COOKIE,
  COOKIE_PATH,
  SESSION_COOKIE,
  type ActorType,
} from './constants'
import {
  isPlatformLocale,
  UI_LOCALE_COOKIE,
  type PlatformLocale,
} from './locale'

export async function readSessionCookie(): Promise<string | null> {
  const jar = await cookies()
  return jar.get(SESSION_COOKIE)?.value ?? null
}

export async function readActorCookie(): Promise<ActorType> {
  const jar = await cookies()
  const v = jar.get(ACTOR_COOKIE)?.value
  if (v === 'staff') return 'staff'
  if (v === 'grant') return 'grant'
  return 'share'
}

export async function readUiLocaleCookie(): Promise<PlatformLocale | null> {
  const jar = await cookies()
  const v = jar.get(UI_LOCALE_COOKIE)?.value?.trim().toLowerCase()
  return v && isPlatformLocale(v) ? v : null
}

export function setUiLocaleCookie(
  response: NextResponse,
  locale: PlatformLocale,
): void {
  const secure = process.env.NODE_ENV === 'production'
  response.cookies.set(UI_LOCALE_COOKIE, locale, {
    httpOnly: true,
    secure,
    sameSite: 'lax',
    path: COOKIE_PATH,
    maxAge: 60 * 60 * 24 * 365,
  })
}

export function setSessionCookies(
  response: NextResponse,
  sessionToken: string,
  actor: ActorType,
  expiresAtIso?: string,
): void {
  const secure = process.env.NODE_ENV === 'production'
  let maxAge = 30 * 60
  if (expiresAtIso) {
    const ms = new Date(expiresAtIso).getTime() - Date.now()
    if (Number.isFinite(ms) && ms > 0) maxAge = Math.floor(ms / 1000)
  }
  response.cookies.set(SESSION_COOKIE, sessionToken, {
    httpOnly: true,
    secure,
    sameSite: 'lax',
    path: COOKIE_PATH,
    maxAge,
  })
  response.cookies.set(ACTOR_COOKIE, actor, {
    httpOnly: true,
    secure,
    sameSite: 'lax',
    path: COOKIE_PATH,
    maxAge,
  })
}

export function clearSessionCookies(response: NextResponse): void {
  const secure = process.env.NODE_ENV === 'production'
  response.cookies.set(SESSION_COOKIE, '', {
    httpOnly: true,
    secure,
    sameSite: 'lax',
    path: COOKIE_PATH,
    maxAge: 0,
  })
  response.cookies.set(ACTOR_COOKIE, '', {
    httpOnly: true,
    secure,
    sameSite: 'lax',
    path: COOKIE_PATH,
    maxAge: 0,
  })
}
