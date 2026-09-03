import { prisma } from '@/lib/prisma'
import { CreateTenantForm } from '@/components/dashboard/CreateTenantForm'
import Link from 'next/link'
import { getT } from '@/lib/i18n/server'

export default async function NewTenantPage() {
  const t = getT('tenants')
  const tc = getT('common')
  const plans = await prisma.plans.findMany({
    where: { is_active: true },
    orderBy: { price_monthly: 'asc' },
    select: {
      id: true,
      name: true,
      display_name: true,
      max_members: true,
      max_storage_mb: true,
      price_monthly: true,
    },
  })

  return (
    <div className="max-w-xl space-y-6">
      {/* Header */}
      <div className="flex items-center gap-3">
        <Link
          href="/dashboard/tenants"
          className="text-sm text-gray-400 hover:text-indigo-600 transition"
        >
          {tc('common.back', '← Enrere')}
        </Link>
        <span className="text-gray-200">/</span>
        <h1 className="text-2xl font-bold text-gray-900">{t('tenants.new.title', 'Nou tenant')}</h1>
      </div>

      <div className="bg-white rounded-2xl border border-gray-100 shadow-sm p-6">
        <CreateTenantForm
          plans={plans.map((p) => ({
            ...p,
            price_monthly: p.price_monthly.toString(),
          }))}
        />
      </div>
    </div>
  )
}
