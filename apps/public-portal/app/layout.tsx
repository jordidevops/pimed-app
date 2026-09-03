import type { Metadata } from 'next'
import { headers } from 'next/headers'
import { Geist } from 'next/font/google'
import './globals.css'
import { cn } from '@/lib/utils'
import { I18nProvider } from '@/components/I18nProvider'
import { PLATFORM_FALLBACK_LOCALE } from '@/lib/locales'

const geist = Geist({ subsets: ['latin'], variable: '--font-sans' })

export const metadata: Metadata = {
  title: {
    default: 'Portal',
    template: '%s | Portal',
  },
  description: 'Portal públic',
}

export default async function RootLayout({ children }: { children: React.ReactNode }) {
  const headersList = await headers()
  const locale = headersList.get('x-locale') ?? PLATFORM_FALLBACK_LOCALE
  return (
    <html lang={locale} className={cn('font-sans', geist.variable)}>
      <body className="min-h-dvh w-full overflow-x-hidden">
        <I18nProvider locale={locale}>{children}</I18nProvider>
      </body>
    </html>
  )
}
