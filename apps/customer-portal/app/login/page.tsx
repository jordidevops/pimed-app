import { headers } from 'next/headers'
import { redirect } from 'next/navigation'
import { I18nProvider } from '@/components/I18nProvider'
import { LoginForm } from '@/components/LoginForm'
import {
  PLATFORM_FALLBACK_LOCALE,
  PLATFORM_LOCALES,
  isPlatformLocale,
  resolveUiLocale,
  type PlatformLocale,
} from '@/lib/locale'
import { requestLoginEmail } from '@/lib/resolver'
import { readUiLocaleCookie } from '@/lib/session'

async function submitLogin(formData: FormData) {
  'use server'
  const email = String(formData.get('email') ?? '').trim()
  if (email) {
    await requestLoginEmail(email)
  }
  redirect('/login?sent=1')
}

function acceptLanguagePreferred(
  header: string | null,
  supported: readonly PlatformLocale[],
): PlatformLocale | null {
  if (!header) return null
  for (const part of header.split(',')) {
    const tag = part.trim().split(';')[0]?.trim().toLowerCase()
    if (!tag) continue
    const primary = tag.slice(0, 2)
    if (isPlatformLocale(primary) && supported.includes(primary)) {
      return primary
    }
  }
  return null
}

export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<{ e?: string; sent?: string }>
}) {
  const sp = await searchParams
  const showSent = sp.sent === '1'
  const showInvalid = sp.e === 'invalid'
  const cookieLocale = await readUiLocaleCookie()
  const hdrs = await headers()
  const fromAccept = acceptLanguagePreferred(
    hdrs.get('accept-language'),
    PLATFORM_LOCALES,
  )
  const uiLocale = resolveUiLocale({
    preferred: fromAccept,
    supported: [...PLATFORM_LOCALES],
    defaultLocale: PLATFORM_FALLBACK_LOCALE,
    cookieLocale,
  })

  return (
    <I18nProvider uiLocale={uiLocale}>
      <LoginForm
        showSent={showSent}
        showInvalid={showInvalid}
        action={submitLogin}
      />
    </I18nProvider>
  )
}
