import { notFound } from 'next/navigation'

/**
 * Arrel del portal: no serveix contingut directament.
 * L'accés es fa sempre via /{slug} o via custom domain (middleware).
 */
export default function RootPage() {
  notFound()
}
