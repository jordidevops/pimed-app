'use client'

import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { createTenant } from '@/app/admin/actions/tenants'
import { provisionAndInviteMember } from '@/app/admin/actions/members'
import { useTranslation } from 'react-i18next'

interface Plan {
  id: string
  name: string
  display_name: string
  max_members: number
  max_storage_mb: number
  price_monthly: string | number
}

interface CreateTenantFormProps {
  plans: Plan[]
}

function toSlug(value: string): string {
  return value
    .toLowerCase()
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
}

export function CreateTenantForm({ plans }: CreateTenantFormProps) {
  const { t } = useTranslation('tenants')
  const router = useRouter()
  const [isPending, startTransition] = useTransition()

  const [name, setName]           = useState('')
  const [slug, setSlug]           = useState('')
  const [planId, setPlanId]       = useState(plans[0]?.id ?? '')
  const [ownerEmail, setOwnerEmail] = useState('')
  const [slugTouched, setSlugTouched] = useState(false)
  const [error, setError]         = useState<string | null>(null)

  function handleNameChange(v: string) {
    setName(v)
    if (!slugTouched) setSlug(toSlug(v))
  }

  function handleSlugChange(v: string) {
    setSlugTouched(true)
    setSlug(toSlug(v))
  }

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    setError(null)

    if (!name.trim()) {
      setError('El nom és obligatori.')
      return
    }
    if (!slug.trim()) {
      setError('El slug és obligatori.')
      return
    }
    if (!planId) {
      setError('Selecciona un pla.')
      return
    }
    if (!ownerEmail.trim()) {
      setError('El correu de l\'owner inicial és obligatori.')
      return
    }
    const emailRe = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
    if (!emailRe.test(ownerEmail.trim())) {
      setError('Introdueix un correu electrònic vàlid per a l\'owner.')
      return
    }

    startTransition(async () => {
      try {
        const tenant = await createTenant({ name, slug, plan_id: planId })
        await provisionAndInviteMember(tenant.id, ownerEmail.trim(), 'owner')
        router.push(`/dashboard/tenants/${tenant.id}?tab=membres`)
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err)
        if (msg.includes('unique') || msg.includes('slug')) {
          setError(t('tenants.new.errors.slug_exists', 'Aquest slug ja existeix. Tria un altre identificador.'))
        } else {
          setError(msg || t('tenants.new.errors.generic', 'Error en crear el tenant. Torna-ho a intentar.'))
        }
      }
    })
  }

  const selectedPlan = plans.find((p) => p.id === planId)

  return (
    <form onSubmit={handleSubmit} className="space-y-6">
      {error && (
        <div className="rounded-lg bg-red-50 border border-red-200 px-4 py-3 text-sm text-red-700">
          {error}
        </div>
      )}

      {/* Nom */}
      <div className="space-y-1.5">
        <label className="block text-sm font-medium text-gray-700">
          {t('tenants.new.form.name_label', 'Nom del tenant')} <span className="text-red-500">*</span>
        </label>
        <input
          type="text"
          value={name}
          onChange={(e) => handleNameChange(e.target.value)}
          placeholder="Ex: Acme Corp"
          disabled={isPending}
          className="w-full text-sm rounded-lg border border-gray-200 px-3 py-2 focus:outline-none focus:ring-2 focus:ring-indigo-400 disabled:opacity-50"
        />
      </div>

      {/* Slug */}
      <div className="space-y-1.5">
        <label className="block text-sm font-medium text-gray-700">
          {t('tenants.new.form.slug_label', 'Slug')} <span className="text-red-500">*</span>
        </label>
        <div className="flex items-center gap-2">
          <span className="text-sm text-gray-400 select-none">example.app/</span>
          <input
            type="text"
            value={slug}
            onChange={(e) => handleSlugChange(e.target.value)}
            placeholder="acme-corp"
            disabled={isPending}
            className="flex-1 text-sm rounded-lg border border-gray-200 px-3 py-2 focus:outline-none focus:ring-2 focus:ring-indigo-400 font-mono disabled:opacity-50"
          />
        </div>
        <p className="text-xs text-gray-400">
          Identificador únic, minúscules i guions. S&apos;omple automàticament.
        </p>
      </div>

      {/* Pla */}
      <div className="space-y-1.5">
        <label className="block text-sm font-medium text-gray-700">
          {t('tenants.new.form.plan_label', 'Pla')} <span className="text-red-500">*</span>
        </label>
        <select
          value={planId}
          onChange={(e) => setPlanId(e.target.value)}
          disabled={isPending}
          className="w-full text-sm rounded-lg border border-gray-200 px-3 py-2 focus:outline-none focus:ring-2 focus:ring-indigo-400 bg-white disabled:opacity-50"
        >
          {plans.map((p) => (
            <option key={p.id} value={p.id}>
              {p.display_name} — {p.max_members} usuaris · {p.max_storage_mb >= 1024 ? `${Math.round(p.max_storage_mb / 1024)} GB` : `${p.max_storage_mb} MB`}
            </option>
          ))}
        </select>

        {selectedPlan && (
          <div className="mt-2 grid grid-cols-3 gap-3">
            <div className="rounded-lg bg-gray-50 px-3 py-2 text-center">
              <p className="text-xs text-gray-400">{t('tenants.new.form.plan_users', 'Usuaris')}</p>
              <p className="text-sm font-semibold text-gray-800">{selectedPlan.max_members}</p>
            </div>
            <div className="rounded-lg bg-gray-50 px-3 py-2 text-center">
              <p className="text-xs text-gray-400">Storage</p>
              <p className="text-sm font-semibold text-gray-800">
                {selectedPlan.max_storage_mb >= 1024
                  ? `${Math.round(selectedPlan.max_storage_mb / 1024)} GB`
                  : `${selectedPlan.max_storage_mb} MB`}
              </p>
            </div>
            <div className="rounded-lg bg-gray-50 px-3 py-2 text-center">
              <p className="text-xs text-gray-400">Preu/mes</p>
              <p className="text-sm font-semibold text-gray-800">
                {Number(selectedPlan.price_monthly) === 0
                  ? t('tenants.new.form.plan_free', 'Grato\u00eft')
                  : `€${Number(selectedPlan.price_monthly).toFixed(2)}`}
              </p>
            </div>
          </div>
        )}
      </div>

      {/* Avís owner — replaced with the actual email field */}
      <div className="space-y-1.5">
        <label className="block text-sm font-medium text-gray-700">
          {t('tenants.new.form.owner_label', "Correu de l'owner inicial")} <span className="text-red-500">*</span>
        </label>
        <input
          type="email"
          value={ownerEmail}
          onChange={(e) => setOwnerEmail(e.target.value)}
          placeholder="owner@empresa.cat"
          disabled={isPending}
          className="w-full text-sm rounded-lg border border-gray-200 px-3 py-2 focus:outline-none focus:ring-2 focus:ring-indigo-400 disabled:opacity-50"
        />
        <p className="text-xs text-gray-400">
          {t('tenants.new.form.owner_hint', "S'enviarà una invitació a aquesta adreça per activar el compte.")}
        </p>
      </div>

      {/* Actions */}
      <div className="flex items-center gap-3">
        <button
          type="submit"
          disabled={isPending || !name || !slug || !planId || !ownerEmail}
          className="px-5 py-2 text-sm font-medium rounded-lg bg-indigo-600 text-white hover:bg-indigo-700 transition disabled:opacity-50 disabled:cursor-not-allowed"
        >
          {isPending ? t('tenants.new.form.submitting', 'Creant i enviant invitació…') : t('tenants.new.form.submit', 'Crear tenant')}
        </button>
        <button
          type="button"
          onClick={() => router.back()}
          disabled={isPending}
          className="px-4 py-2 text-sm font-medium rounded-lg text-gray-600 hover:text-gray-900 transition disabled:opacity-50"
        >
          {t('tenants.new.form.cancel', 'Cancel·lar')}
        </button>
      </div>
    </form>
  )
}
