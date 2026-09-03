import { Suspense } from 'react'
import { VerifyApplicantEmailClient } from '@/components/VerifyApplicantEmailClient'

export const metadata = {
  title: 'Verificació de correu',
  robots: { index: false, follow: false },
}

export default function RecruitmentVerifyPage() {
  return (
    <Suspense fallback={<div className="p-10 text-center">…</div>}>
      <VerifyApplicantEmailClient />
    </Suspense>
  )
}
