import { I18nProvider } from '@/components/I18nProvider'
import { HomeContent } from '@/components/HomeContent'
import { PLATFORM_FALLBACK_LOCALE, resolveUiLocale } from '@/lib/locale'
import { readUiLocaleCookie } from '@/lib/session'

export default async function HomePage({
  searchParams,
}: {
  searchParams: Promise<{ e?: string }>
}) {
  const sp = await searchParams
  const cookieLocale = await readUiLocaleCookie()
  const uiLocale = resolveUiLocale({
    preferred: null,
    supported: ['ca', 'es', 'en'],
    defaultLocale: PLATFORM_FALLBACK_LOCALE,
    cookieLocale,
  })

  return (
    <I18nProvider uiLocale={uiLocale}>
      <HomeContent errorParam={sp.e} />
    </I18nProvider>
  )
}
