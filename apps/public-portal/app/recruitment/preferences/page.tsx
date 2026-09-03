import { Suspense } from 'react'
import { PostRejectionPreferencesClient } from '@/components/PostRejectionPreferencesClient'

export const metadata = {
  title: 'Preferències de dades',
  robots: { index: false, follow: false },
}

export default function RecruitmentPreferencesPage() {
  return (
    <Suspense fallback={<div className="p-10 text-center">…</div>}>
      <PostRejectionPreferencesClient />
    </Suspense>
  )
}
