import type { Metadata } from 'next'
import { Inter, Geist } from 'next/font/google'
import { Analytics } from '@vercel/analytics/next'
import './globals.css'
import { cn } from "@/lib/utils";
import { I18nProvider } from '@/components/I18nProvider'
import { ObservabilityProvider } from '@/components/ObservabilityProvider'

const geist = Geist({subsets:['latin'],variable:'--font-sans'});


// Totes les pàgines són dinàmiques: l'app requereix auth i BD en cada request.
// Evita que Next.js intenti pre-renderitzar cap pàgina durant el build.
export const dynamic = 'force-dynamic'

const inter = Inter({ subsets: ['latin'] })

export const metadata: Metadata = {
  title: 'Admin Portal',
  description: 'Portal de gestió de tenants de la plataforma',
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="ca" className={cn("font-sans", geist.variable)}>
      <body className={inter.className}>
        <I18nProvider>
          <ObservabilityProvider>
            {children}
          </ObservabilityProvider>
        </I18nProvider>
        <Analytics />
      </body>
    </html>
  )
}
