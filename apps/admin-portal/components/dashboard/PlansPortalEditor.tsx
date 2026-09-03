'use client'

import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import {
  updatePlanPortalEntitlements,
  type PlanPortalRow,
} from '@/app/admin/actions/portal-entitlements'

const CMS_TIERS = ['none', 'basic', 'advanced'] as const
const CP_MODES = ['share_only', 'portal'] as const

interface Props {
  plans: PlanPortalRow[]
}

type ChannelForm = {
  included: boolean
  cms_tier: string
  max_pages?: number
}

type CustomerForm = {
  included: boolean
  mode: string
  active_share_guardrail: number
  customer_mau_alert_threshold: number
  included_email_deliveries_month: number
}

type PlanForm = {
  employee: ChannelForm
  public: ChannelForm
  customer: CustomerForm
}

function parseEntitlements(raw: Record<string, unknown>): PlanForm {
  const emp = (raw?.employee_portal ?? {}) as Record<string, unknown>
  const pub = (raw?.public_portal ?? {}) as Record<string, unknown>
  const cp = (raw?.customer_portal ?? {}) as Record<string, unknown>
  return {
    employee: {
      included: Boolean(emp.included),
      cms_tier: String(emp.cms_tier ?? 'basic'),
    },
    public: {
      included: Boolean(pub.included),
      cms_tier: String(pub.cms_tier ?? 'none'),
      max_pages: Number(pub.max_pages ?? 0),
    },
    customer: {
      included: Boolean(cp.included ?? true),
      mode: String(cp.mode ?? 'share_only'),
      active_share_guardrail: Number(cp.active_share_guardrail ?? 500),
      customer_mau_alert_threshold: Number(cp.customer_mau_alert_threshold ?? 1000),
      included_email_deliveries_month: Number(cp.included_email_deliveries_month ?? 2000),
    },
  }
}

export function PlansPortalEditor({ plans }: Props) {
  const router = useRouter()
  const [isPending, startTransition] = useTransition()
  const [savedPlanId, setSavedPlanId] = useState<string | null>(null)
  const [forms, setForms] = useState<Record<string, PlanForm>>(() =>
    Object.fromEntries(plans.map((p) => [p.id, parseEntitlements(p.portal_entitlements)])),
  )

  function updateChannel(
    planId: string,
    channel: 'employee' | 'public',
    patch: Partial<ChannelForm>,
  ) {
    setForms((prev) => ({
      ...prev,
      [planId]: {
        ...prev[planId],
        [channel]: { ...prev[planId][channel], ...patch },
      },
    }))
  }

  function updateCustomer(planId: string, patch: Partial<CustomerForm>) {
    setForms((prev) => ({
      ...prev,
      [planId]: {
        ...prev[planId],
        customer: { ...prev[planId].customer, ...patch },
      },
    }))
  }

  function handleSave(plan: PlanPortalRow) {
    const form = forms[plan.id]
    const existing = (plan.portal_entitlements ?? {}) as Record<string, unknown>
    const entitlements = {
      ...existing,
      employee_portal: {
        ...((existing.employee_portal as Record<string, unknown>) ?? {}),
        included: form.employee.included,
        cms_tier: form.employee.cms_tier,
      },
      public_portal: {
        ...((existing.public_portal as Record<string, unknown>) ?? {}),
        included: form.public.included,
        cms_tier: form.public.cms_tier,
        max_pages: form.public.max_pages ?? plan.max_portal_pages,
      },
      customer_portal: {
        ...((existing.customer_portal as Record<string, unknown>) ?? {}),
        included: form.customer.included,
        mode: form.customer.mode,
        active_share_guardrail: form.customer.active_share_guardrail,
        customer_mau_alert_threshold: form.customer.customer_mau_alert_threshold,
        included_email_deliveries_month: form.customer.included_email_deliveries_month,
      },
    }

    startTransition(async () => {
      await updatePlanPortalEntitlements(plan.id, entitlements)
      setSavedPlanId(plan.id)
      router.refresh()
      setTimeout(() => setSavedPlanId(null), 2000)
    })
  }

  return (
    <div className="rounded-xl border border-gray-200 bg-white overflow-hidden shadow-sm">
      <div className="overflow-x-auto">
        <table className="w-full text-sm min-w-[960px]">
          <thead>
            <tr className="border-b bg-gray-50">
              <th className="text-left px-4 py-3 font-medium text-gray-500">Pla</th>
              <th className="text-left px-4 py-3 font-medium text-gray-500">Portal empleat</th>
              <th className="text-left px-4 py-3 font-medium text-gray-500">Web pública</th>
              <th className="text-left px-4 py-3 font-medium text-gray-500">Portal client</th>
              <th className="text-left px-4 py-3 font-medium text-gray-500">max_portal_pages</th>
              <th className="px-4 py-3" />
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100">
            {plans.map((plan) => {
              const form = forms[plan.id]
              if (!form) return null
              return (
                <tr key={plan.id}>
                  <td className="px-4 py-4 align-top">
                    <p className="font-medium text-gray-900">{plan.display_name}</p>
                    <p className="text-xs text-gray-400 font-mono">{plan.name}</p>
                  </td>
                  <td className="px-4 py-4 align-top space-y-2">
                    <label className="flex items-center gap-2 text-xs">
                      <input
                        type="checkbox"
                        checked={form.employee.included}
                        onChange={(e) =>
                          updateChannel(plan.id, 'employee', { included: e.target.checked })
                        }
                      />
                      Inclòs
                    </label>
                    <select
                      value={form.employee.cms_tier}
                      onChange={(e) =>
                        updateChannel(plan.id, 'employee', { cms_tier: e.target.value })
                      }
                      className="w-full rounded border border-gray-200 px-2 py-1 text-xs"
                    >
                      {CMS_TIERS.map((t) => (
                        <option key={t} value={t}>{t}</option>
                      ))}
                    </select>
                  </td>
                  <td className="px-4 py-4 align-top space-y-2">
                    <label className="flex items-center gap-2 text-xs">
                      <input
                        type="checkbox"
                        checked={form.public.included}
                        onChange={(e) =>
                          updateChannel(plan.id, 'public', { included: e.target.checked })
                        }
                      />
                      Inclòs
                    </label>
                    <select
                      value={form.public.cms_tier}
                      onChange={(e) =>
                        updateChannel(plan.id, 'public', { cms_tier: e.target.value })
                      }
                      className="w-full rounded border border-gray-200 px-2 py-1 text-xs"
                    >
                      {CMS_TIERS.map((t) => (
                        <option key={t} value={t}>{t}</option>
                      ))}
                    </select>
                    <label className="block text-xs text-gray-500">
                      max_pages (portal_entitlements)
                      <input
                        type="number"
                        min={0}
                        value={form.public.max_pages ?? 0}
                        onChange={(e) =>
                          updateChannel(plan.id, 'public', {
                            max_pages: parseInt(e.target.value, 10) || 0,
                          })
                        }
                        className="mt-1 w-full rounded border border-gray-200 px-2 py-1"
                      />
                    </label>
                  </td>
                  <td className="px-4 py-4 align-top space-y-2">
                    <label className="flex items-center gap-2 text-xs">
                      <input
                        type="checkbox"
                        checked={form.customer.included}
                        onChange={(e) =>
                          updateCustomer(plan.id, { included: e.target.checked })
                        }
                      />
                      Inclòs
                    </label>
                    <label className="block text-xs text-gray-500">
                      mode
                      <select
                        value={form.customer.mode}
                        onChange={(e) => updateCustomer(plan.id, { mode: e.target.value })}
                        className="mt-1 w-full rounded border border-gray-200 px-2 py-1 text-xs"
                      >
                        {CP_MODES.map((m) => (
                          <option key={m} value={m}>{m}</option>
                        ))}
                      </select>
                    </label>
                    <label className="block text-xs text-gray-500">
                      active_share_guardrail
                      <input
                        type="number"
                        min={0}
                        value={form.customer.active_share_guardrail}
                        onChange={(e) =>
                          updateCustomer(plan.id, {
                            active_share_guardrail: parseInt(e.target.value, 10) || 0,
                          })
                        }
                        className="mt-1 w-full rounded border border-gray-200 px-2 py-1"
                      />
                    </label>
                    <label className="block text-xs text-gray-500">
                      customer_mau_alert_threshold
                      <input
                        type="number"
                        min={0}
                        value={form.customer.customer_mau_alert_threshold}
                        onChange={(e) =>
                          updateCustomer(plan.id, {
                            customer_mau_alert_threshold: parseInt(e.target.value, 10) || 0,
                          })
                        }
                        className="mt-1 w-full rounded border border-gray-200 px-2 py-1"
                      />
                    </label>
                    <label className="block text-xs text-gray-500">
                      included_email_deliveries_month
                      <input
                        type="number"
                        min={0}
                        value={form.customer.included_email_deliveries_month}
                        onChange={(e) =>
                          updateCustomer(plan.id, {
                            included_email_deliveries_month: parseInt(e.target.value, 10) || 0,
                          })
                        }
                        className="mt-1 w-full rounded border border-gray-200 px-2 py-1"
                      />
                    </label>
                  </td>
                  <td className="px-4 py-4 align-top text-xs text-gray-600">
                    {plan.max_portal_pages === 0 ? '0 (= il·limitat legacy)' : plan.max_portal_pages}
                  </td>
                  <td className="px-4 py-4 align-top">
                    <button
                      type="button"
                      onClick={() => handleSave(plan)}
                      disabled={isPending}
                      className="px-3 py-1.5 text-xs font-medium rounded-lg bg-indigo-600 text-white hover:bg-indigo-700 disabled:opacity-50"
                    >
                      {savedPlanId === plan.id ? 'Desat ✓' : 'Desar'}
                    </button>
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>
    </div>
  )
}
