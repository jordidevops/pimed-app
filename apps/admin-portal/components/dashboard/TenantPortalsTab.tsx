'use client'

import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import {
  getPortalEntitlements,
  setCustomerPortalTenantPolicies,
  syncPortalEntitlementsWithPlan,
  toggleCustomerPortalTenant,
  toggleEmployeePortal,
  upsertTenantPortalEntitlements,
  type PortalEntitlements,
  type TenantPortalEntitlementsSnapshot,
} from '@/app/admin/actions/portal-entitlements'
import { togglePublicPortal } from '@/app/admin/actions/tenants'

const CMS_TIERS = ['none', 'basic', 'advanced'] as const
const CP_MODES = ['share_only', 'portal'] as const

interface Props {
  tenantId: string
  planName: string
  initial: PortalEntitlements
  employeePortalEnabled: boolean
  publicPortalEnabled: boolean
  snapshot: TenantPortalEntitlementsSnapshot
}

function tierBadge(tier: string) {
  const colors: Record<string, string> = {
    advanced: 'bg-purple-50 text-purple-700',
    basic: 'bg-blue-50 text-blue-700',
    none: 'bg-gray-100 text-gray-500',
  }
  return (
    <span className={`px-2 py-0.5 text-xs font-medium rounded-full ${colors[tier] ?? colors.none}`}>
      {tier}
    </span>
  )
}

function effectiveBadge(effective: boolean) {
  return (
    <span
      className={`px-2 py-0.5 text-xs font-medium rounded-full ${
        effective ? 'bg-green-50 text-green-700' : 'bg-gray-100 text-gray-500'
      }`}
    >
      {effective ? 'Efectiu' : 'Inactiu'}
    </span>
  )
}

function yesNo(value: boolean | undefined) {
  return value ? 'Sí' : 'No'
}

export function TenantPortalsTab({
  tenantId,
  planName,
  initial,
  employeePortalEnabled,
  publicPortalEnabled,
  snapshot,
}: Props) {
  const router = useRouter()
  const [isPending, startTransition] = useTransition()
  const [entitlements, setEntitlements] = useState(initial)
  const [form, setForm] = useState(() => ({
    empIncluded: snapshot?.employee_portal?.included ?? false,
    empTier: snapshot?.employee_portal?.cms_tier ?? 'basic',
    pubIncluded: snapshot?.public_portal?.included ?? false,
    pubTier: snapshot?.public_portal?.cms_tier ?? 'basic',
    pubMaxPages: snapshot?.public_portal?.max_pages ?? 0,
    cpIncluded: snapshot?.customer_portal?.included ?? false,
    cpMode: snapshot?.customer_portal?.mode ?? 'share_only',
    cpGuardrail: snapshot?.customer_portal?.active_share_guardrail ?? 500,
    cpMau: snapshot?.customer_portal?.customer_mau_alert_threshold ?? 1000,
    cpEmails: snapshot?.customer_portal?.included_email_deliveries_month ?? 2000,
    cpUsersLimit:
      snapshot?.customer_portal?.customer_users_limit == null
        ? ''
        : String(snapshot.customer_portal.customer_users_limit),
  }))
  const [policies, setPolicies] = useState(() => ({
    new_share_policy: initial.customer_portal?.new_share_policy ?? 'allow',
    new_access_policy: initial.customer_portal?.new_access_policy ?? 'allow',
    existing_access_policy: initial.customer_portal?.existing_access_policy ?? 'allow',
    note: '',
  }))
  const [message, setMessage] = useState<string | null>(null)

  function flash(msg: string) {
    setMessage(msg)
    setTimeout(() => setMessage(null), 2500)
  }

  function syncFormFromSnapshot(snap: TenantPortalEntitlementsSnapshot) {
    setForm({
      empIncluded: snap.employee_portal?.included ?? false,
      empTier: snap.employee_portal?.cms_tier ?? 'basic',
      pubIncluded: snap.public_portal?.included ?? false,
      pubTier: snap.public_portal?.cms_tier ?? 'basic',
      pubMaxPages: snap.public_portal?.max_pages ?? 0,
      cpIncluded: snap.customer_portal?.included ?? false,
      cpMode: snap.customer_portal?.mode ?? 'share_only',
      cpGuardrail: snap.customer_portal?.active_share_guardrail ?? 500,
      cpMau: snap.customer_portal?.customer_mau_alert_threshold ?? 1000,
      cpEmails: snap.customer_portal?.included_email_deliveries_month ?? 2000,
      cpUsersLimit:
        snap.customer_portal?.customer_users_limit == null
          ? ''
          : String(snap.customer_portal.customer_users_limit),
    })
  }

  function refresh(next: PortalEntitlements) {
    setEntitlements(next)
    syncFormFromSnapshot(next.tenant_portal_entitlements ?? {})
    setPolicies((p) => ({
      ...p,
      new_share_policy: next.customer_portal?.new_share_policy ?? 'allow',
      new_access_policy: next.customer_portal?.new_access_policy ?? 'allow',
      existing_access_policy: next.customer_portal?.existing_access_policy ?? 'allow',
    }))
    router.refresh()
  }

  function handleToggleEmployee() {
    startTransition(async () => {
      await toggleEmployeePortal(tenantId, !employeePortalEnabled)
      const next = await getPortalEntitlements(tenantId)
      refresh(next)
      flash('Desat ✓')
    })
  }

  function handleTogglePublic() {
    startTransition(async () => {
      await togglePublicPortal(tenantId, !publicPortalEnabled)
      const next = await getPortalEntitlements(tenantId)
      refresh(next)
      flash('Desat ✓')
    })
  }

  function handleToggleCustomer() {
    const enable = !(entitlements.customer_portal?.enabled_by_tenant ?? false)
    startTransition(async () => {
      await toggleCustomerPortalTenant(tenantId, enable)
      const next = await getPortalEntitlements(tenantId)
      refresh(next)
      flash('Desat ✓')
    })
  }

  function handleSaveSnapshot() {
    startTransition(async () => {
      const payload: TenantPortalEntitlementsSnapshot = {
        employee_portal: {
          included: form.empIncluded,
          cms_tier: form.empTier,
        },
        public_portal: {
          included: form.pubIncluded,
          cms_tier: form.pubTier,
          max_pages: form.pubMaxPages,
        },
        customer_portal: {
          included: form.cpIncluded,
          mode: form.cpMode,
          active_share_guardrail: form.cpGuardrail,
          customer_mau_alert_threshold: form.cpMau,
          included_email_deliveries_month: form.cpEmails,
          customer_users_limit: form.cpUsersLimit === '' ? null : parseInt(form.cpUsersLimit, 10) || 0,
        },
      }
      const next = await upsertTenantPortalEntitlements(tenantId, payload)
      refresh(next)
      flash('Contracte del tenant desat ✓')
    })
  }

  function handleSavePolicies() {
    startTransition(async () => {
      await setCustomerPortalTenantPolicies(tenantId, {
        new_share_policy: policies.new_share_policy as 'allow' | 'blocked',
        new_access_policy: policies.new_access_policy as 'allow' | 'review' | 'blocked',
        existing_access_policy: policies.existing_access_policy as 'allow' | 'blocked',
        note: policies.note.trim() || null,
      })
      const next = await getPortalEntitlements(tenantId)
      refresh(next)
      flash('Polítiques del portal client desades ✓')
    })
  }

  function handleSync() {
    startTransition(async () => {
      const next = await syncPortalEntitlementsWithPlan(tenantId)
      refresh(next)
      flash('Millores del pla aplicades al contracte ✓')
    })
  }

  const emp = entitlements.employee_portal
  const pub = entitlements.public_portal
  const cp = entitlements.customer_portal
  const cpGranted = cp?.included_granted ?? false
  const cpEnabled = cp?.enabled_by_tenant ?? false

  return (
    <div className="space-y-6">
      {message && (
        <p className="text-sm text-green-600 font-medium">{message}</p>
      )}

      <section className="rounded-2xl border border-indigo-100 bg-indigo-50/50 p-5 text-sm text-indigo-950 space-y-2">
        <h3 className="font-semibold">Com funciona (TCMS-1.1)</h3>
        <ul className="list-disc pl-5 space-y-1 text-indigo-900/90">
          <li>
            <strong>Pla</strong> ({planName}): valors per defecte per a <em>nous</em> tenants.
            Canviar el pla aquí no empitjora tenants existents automàticament.
          </li>
          <li>
            <strong>Contracte del tenant</strong> (<code className="text-xs">tenant_portal_entitlements</code>):
            drets concedits i emmagatzemats. No baixen quan el pla empitjora (grandfathering).
          </li>
          <li>
            <strong>Efectiu</strong> = contracte concedit + toggle «Activat per tenant» (+ plataforma per portal client).
          </li>
          <li>
            <strong>Sync amb pla</strong>: aplica només <em>millores</em> del pla al contracte (tier, pàgines, inclusió, mode).
            No desactiva toggles ni treu portals actius.
          </li>
        </ul>
      </section>

      <section className="bg-white rounded-2xl border border-gray-100 p-6 shadow-sm space-y-5">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h3 className="text-base font-semibold text-gray-900">Estat en temps real</h3>
            <p className="text-sm text-gray-500 mt-1">
              Pla actual: <span className="font-medium text-gray-700">{planName}</span>
            </p>
          </div>
          <button
            type="button"
            onClick={handleSync}
            disabled={isPending}
            className="px-3 py-1.5 text-sm font-medium rounded-lg border border-gray-200 hover:bg-gray-50 disabled:opacity-50"
          >
            Sync millores del pla
          </button>
        </div>

        <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
          <div className="rounded-xl border border-gray-100 p-4 space-y-3">
            <div className="flex items-center justify-between">
              <h4 className="text-sm font-semibold text-gray-800">Portal empleat</h4>
              {effectiveBadge(emp.effective)}
            </div>
            <dl className="text-xs space-y-1 text-gray-600">
              <div className="flex justify-between">
                <dt>Concedit (contracte)</dt>
                <dd>{emp.included_granted ?? emp.included_by_plan ? 'Sí' : 'No'}</dd>
              </div>
              <div className="flex justify-between">
                <dt>Pla actual inclou</dt>
                <dd>{emp.included_plan ? 'Sí' : 'No'}</dd>
              </div>
              <div className="flex justify-between items-center">
                <dt>CMS tier efectiu</dt>
                <dd>{tierBadge(emp.cms_tier)}</dd>
              </div>
              <div className="flex justify-between text-gray-400">
                <dt>Contracte / pla</dt>
                <dd>{emp.cms_tier_granted ?? emp.cms_tier} / {emp.cms_tier_plan ?? '—'}</dd>
              </div>
            </dl>
            <label className="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                checked={employeePortalEnabled}
                onChange={handleToggleEmployee}
                disabled={isPending || !(emp.included_granted ?? emp.included_by_plan)}
                className="rounded border-gray-300"
              />
              <span className={!(emp.included_granted ?? emp.included_by_plan) ? 'text-gray-400' : 'text-gray-700'}>
                Activat per tenant
              </span>
            </label>
          </div>

          <div className="rounded-xl border border-gray-100 p-4 space-y-3">
            <div className="flex items-center justify-between">
              <h4 className="text-sm font-semibold text-gray-800">Web pública</h4>
              {effectiveBadge(pub.effective)}
            </div>
            <dl className="text-xs space-y-1 text-gray-600">
              <div className="flex justify-between">
                <dt>Concedit (contracte)</dt>
                <dd>{pub.included_granted ?? pub.included_by_plan ? 'Sí' : 'No'}</dd>
              </div>
              <div className="flex justify-between">
                <dt>Pla actual inclou</dt>
                <dd>{pub.included_plan ? 'Sí' : 'No'}</dd>
              </div>
              <div className="flex justify-between items-center">
                <dt>CMS tier efectiu</dt>
                <dd>{tierBadge(pub.cms_tier)}</dd>
              </div>
              <div className="flex justify-between">
                <dt>Màx. pàgines / site (efectiu)</dt>
                <dd>{pub.max_pages === 0 ? 'Il·limitat' : pub.max_pages}</dd>
              </div>
              <div className="flex justify-between text-gray-400">
                <dt>Contracte / pla</dt>
                <dd>
                  {pub.max_pages_granted === 0 ? '∞' : pub.max_pages_granted} /{' '}
                  {pub.max_pages_plan === 0 ? '∞' : pub.max_pages_plan}
                </dd>
              </div>
            </dl>
            <label className="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                checked={publicPortalEnabled}
                onChange={handleTogglePublic}
                disabled={isPending || !(pub.included_granted ?? pub.included_by_plan)}
                className="rounded border-gray-300"
              />
              <span className={!(pub.included_granted ?? pub.included_by_plan) ? 'text-gray-400' : 'text-gray-700'}>
                Activat per tenant
              </span>
            </label>
          </div>

          <div className="rounded-xl border border-indigo-100 p-4 space-y-3">
            <div className="flex items-center justify-between">
              <h4 className="text-sm font-semibold text-gray-800">Portal client</h4>
              {effectiveBadge(cp?.effective ?? false)}
            </div>
            <dl className="text-xs space-y-1 text-gray-600">
              <div className="flex justify-between">
                <dt>Concedit (contracte)</dt>
                <dd>{yesNo(cpGranted)}</dd>
              </div>
              <div className="flex justify-between">
                <dt>Pla actual inclou</dt>
                <dd>{yesNo(cp?.included_plan)}</dd>
              </div>
              <div className="flex justify-between">
                <dt>Mode efectiu</dt>
                <dd className="font-mono">{cp?.mode_effective ?? '—'}</dd>
              </div>
              <div className="flex justify-between text-gray-400">
                <dt>Contracte / pla</dt>
                <dd>{cp?.mode_granted ?? '—'} / {cp?.mode_plan ?? '—'}</dd>
              </div>
              <div className="flex justify-between">
                <dt>platform_max_mode</dt>
                <dd className="font-mono">{cp?.platform_max_mode ?? '—'}</dd>
              </div>
              <div className="flex justify-between">
                <dt>Plataforma activada</dt>
                <dd>{yesNo(cp?.enabled_by_platform)}</dd>
              </div>
              <div className="flex justify-between">
                <dt>can_create_shares</dt>
                <dd>{yesNo(cp?.can_create_shares)}</dd>
              </div>
              <div className="flex justify-between">
                <dt>can_grant_portal_access</dt>
                <dd>{yesNo(cp?.can_grant_portal_access)}</dd>
              </div>
              <div className="flex justify-between text-gray-400">
                <dt>Polítiques</dt>
                <dd className="text-right">
                  {cp?.new_share_policy ?? '—'} / {cp?.new_access_policy ?? '—'} /{' '}
                  {cp?.existing_access_policy ?? '—'}
                </dd>
              </div>
            </dl>
            <label className="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                checked={cpEnabled}
                onChange={handleToggleCustomer}
                disabled={isPending || !cpGranted}
                className="rounded border-gray-300"
              />
              <span className={!cpGranted ? 'text-gray-400' : 'text-gray-700'}>
                Activat per tenant
              </span>
            </label>
          </div>
        </div>
      </section>

      <section className="bg-white rounded-2xl border border-gray-100 p-6 shadow-sm space-y-4">
        <h3 className="text-base font-semibold text-gray-900">Contracte del tenant (editable)</h3>
        <p className="text-sm text-gray-500">
          Aquests valors es guarden al tenant i no empitjoren quan el pla baixa. Pots concedir més del pla actual
          (suport / enterprise manual). Posar «Inclòs = No» revoca el dret encara que el pla l&apos;inclogui.
        </p>
        <div className="grid gap-6 lg:grid-cols-3">
          <fieldset className="space-y-3 rounded-xl border border-gray-100 p-4">
            <legend className="text-sm font-medium text-gray-800 px-1">Portal empleat</legend>
            <label className="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                checked={form.empIncluded}
                onChange={(e) => setForm((f) => ({ ...f, empIncluded: e.target.checked }))}
              />
              Mòdul concedit
            </label>
            <label className="block text-sm">
              <span className="text-gray-600 mb-1 block">CMS tier</span>
              <select
                value={form.empTier}
                onChange={(e) => setForm((f) => ({ ...f, empTier: e.target.value }))}
                className="w-full rounded-lg border border-gray-200 px-3 py-2 text-sm"
              >
                {CMS_TIERS.filter((t) => t !== 'none').map((t) => (
                  <option key={t} value={t}>{t}</option>
                ))}
              </select>
            </label>
          </fieldset>

          <fieldset className="space-y-3 rounded-xl border border-gray-100 p-4">
            <legend className="text-sm font-medium text-gray-800 px-1">Web pública</legend>
            <label className="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                checked={form.pubIncluded}
                onChange={(e) => setForm((f) => ({ ...f, pubIncluded: e.target.checked }))}
              />
              Mòdul concedit
            </label>
            <label className="block text-sm">
              <span className="text-gray-600 mb-1 block">CMS tier</span>
              <select
                value={form.pubTier}
                onChange={(e) => setForm((f) => ({ ...f, pubTier: e.target.value }))}
                className="w-full rounded-lg border border-gray-200 px-3 py-2 text-sm"
              >
                {CMS_TIERS.filter((t) => t !== 'none').map((t) => (
                  <option key={t} value={t}>{t}</option>
                ))}
              </select>
            </label>
            <label className="block text-sm">
              <span className="text-gray-600 mb-1 block">Màx. pàgines / site (0 = il·limitat)</span>
              <input
                type="number"
                min={0}
                value={form.pubMaxPages}
                onChange={(e) =>
                  setForm((f) => ({ ...f, pubMaxPages: parseInt(e.target.value, 10) || 0 }))
                }
                className="w-full rounded-lg border border-gray-200 px-3 py-2 text-sm"
              />
            </label>
          </fieldset>

          <fieldset className="space-y-3 rounded-xl border border-indigo-100 p-4">
            <legend className="text-sm font-medium text-gray-800 px-1">Portal client</legend>
            <label className="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                checked={form.cpIncluded}
                onChange={(e) => setForm((f) => ({ ...f, cpIncluded: e.target.checked }))}
              />
              Mòdul concedit
            </label>
            <label className="block text-sm">
              <span className="text-gray-600 mb-1 block">Mode</span>
              <select
                value={form.cpMode}
                onChange={(e) => setForm((f) => ({ ...f, cpMode: e.target.value }))}
                className="w-full rounded-lg border border-gray-200 px-3 py-2 text-sm"
              >
                {CP_MODES.map((m) => (
                  <option key={m} value={m}>{m}</option>
                ))}
              </select>
            </label>
            <label className="block text-sm">
              <span className="text-gray-600 mb-1 block">active_share_guardrail</span>
              <input
                type="number"
                min={0}
                value={form.cpGuardrail}
                onChange={(e) =>
                  setForm((f) => ({ ...f, cpGuardrail: parseInt(e.target.value, 10) || 0 }))
                }
                className="w-full rounded-lg border border-gray-200 px-3 py-2 text-sm"
              />
            </label>
            <label className="block text-sm">
              <span className="text-gray-600 mb-1 block">customer_mau_alert_threshold</span>
              <input
                type="number"
                min={0}
                value={form.cpMau}
                onChange={(e) =>
                  setForm((f) => ({ ...f, cpMau: parseInt(e.target.value, 10) || 0 }))
                }
                className="w-full rounded-lg border border-gray-200 px-3 py-2 text-sm"
              />
            </label>
            <label className="block text-sm">
              <span className="text-gray-600 mb-1 block">included_email_deliveries_month</span>
              <input
                type="number"
                min={0}
                value={form.cpEmails}
                onChange={(e) =>
                  setForm((f) => ({ ...f, cpEmails: parseInt(e.target.value, 10) || 0 }))
                }
                className="w-full rounded-lg border border-gray-200 px-3 py-2 text-sm"
              />
            </label>
            <label className="block text-sm">
              <span className="text-gray-600 mb-1 block">customer_users_limit (buit = null)</span>
              <input
                type="number"
                min={0}
                value={form.cpUsersLimit}
                onChange={(e) => setForm((f) => ({ ...f, cpUsersLimit: e.target.value }))}
                className="w-full rounded-lg border border-gray-200 px-3 py-2 text-sm"
                placeholder="null"
              />
            </label>
          </fieldset>
        </div>
        <button
          type="button"
          onClick={handleSaveSnapshot}
          disabled={isPending}
          className="px-4 py-2 text-sm font-medium rounded-lg bg-indigo-600 text-white hover:bg-indigo-700 disabled:opacity-50"
        >
          Desar contracte del tenant
        </button>
      </section>

      <section className="bg-white rounded-2xl border border-indigo-100 p-6 shadow-sm space-y-4">
        <div>
          <h3 className="text-base font-semibold text-gray-900">Polítiques operatives (portal client)</h3>
          <p className="text-sm text-gray-500 mt-1">
            Kill-switch de polítiques per tenant. No modifica el contracte employee/public.
          </p>
        </div>
        <div className="grid gap-4 sm:grid-cols-3">
          <label className="block text-sm">
            <span className="text-gray-600 mb-1 block">new_share_policy</span>
            <select
              value={policies.new_share_policy}
              onChange={(e) => setPolicies((p) => ({ ...p, new_share_policy: e.target.value }))}
              className="w-full rounded-lg border border-gray-200 px-3 py-2 text-sm"
            >
              <option value="allow">allow</option>
              <option value="blocked">blocked</option>
            </select>
          </label>
          <label className="block text-sm">
            <span className="text-gray-600 mb-1 block">new_access_policy</span>
            <select
              value={policies.new_access_policy}
              onChange={(e) => setPolicies((p) => ({ ...p, new_access_policy: e.target.value }))}
              className="w-full rounded-lg border border-gray-200 px-3 py-2 text-sm"
            >
              <option value="allow">allow</option>
              <option value="review">review</option>
              <option value="blocked">blocked</option>
            </select>
          </label>
          <label className="block text-sm">
            <span className="text-gray-600 mb-1 block">existing_access_policy</span>
            <select
              value={policies.existing_access_policy}
              onChange={(e) =>
                setPolicies((p) => ({ ...p, existing_access_policy: e.target.value }))
              }
              className="w-full rounded-lg border border-gray-200 px-3 py-2 text-sm"
            >
              <option value="allow">allow</option>
              <option value="blocked">blocked</option>
            </select>
          </label>
        </div>
        <label className="block text-sm max-w-xl">
          <span className="text-gray-600 mb-1 block">Nota (opcional)</span>
          <input
            type="text"
            value={policies.note}
            onChange={(e) => setPolicies((p) => ({ ...p, note: e.target.value }))}
            className="w-full rounded-lg border border-gray-200 px-3 py-2 text-sm"
            placeholder="Motiu / context ops"
          />
        </label>
        <button
          type="button"
          onClick={handleSavePolicies}
          disabled={isPending}
          className="px-4 py-2 text-sm font-medium rounded-lg bg-indigo-600 text-white hover:bg-indigo-700 disabled:opacity-50"
        >
          Desar polítiques
        </button>
      </section>

      <section className="bg-white rounded-2xl border border-gray-100 p-6 shadow-sm space-y-3">
        <h3 className="text-base font-semibold text-gray-900">JSON resolt (debug)</h3>
        <pre className="text-xs bg-gray-50 rounded-lg p-4 overflow-x-auto text-gray-700">
          {JSON.stringify(entitlements, null, 2)}
        </pre>
        {Object.keys(pub.pages_used_by_site ?? {}).length > 0 && (
          <div>
            <p className="text-xs font-medium text-gray-500 mb-2">Pàgines per site</p>
            <ul className="text-xs text-gray-600 space-y-1">
              {Object.entries(pub.pages_used_by_site ?? {}).map(([siteId, count]) => (
                <li key={siteId}>
                  <span className="font-mono">{siteId.slice(0, 8)}…</span>: {count} pàgines
                </li>
              ))}
            </ul>
          </div>
        )}
      </section>
    </div>
  )
}
