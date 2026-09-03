'use client'

import { useState, useTransition } from 'react'
import {
  setCustomerPortalPlatformEnabled,
  setCustomerPortalPlatformMaxMode,
  type CustomerPortalPlatformState,
} from '@/app/admin/actions/portal-entitlements'

interface Props {
  initial: CustomerPortalPlatformState
  canEdit: boolean
}

const MAX_MODES = ['share_only', 'portal'] as const

export function AdminCustomerPortalOpsPanel({ initial, canEdit }: Props) {
  const [isPending, startTransition] = useTransition()
  const [state, setState] = useState<CustomerPortalPlatformState>(initial)
  const [maxMode, setMaxMode] = useState(initial.max_mode ?? 'share_only')
  const [note, setNote] = useState('')
  const [savedMsg, setSavedMsg] = useState<string | null>(null)
  const [errorMsg, setErrorMsg] = useState<string | null>(null)

  function showSaved() {
    setSavedMsg('Desat ✓')
    setTimeout(() => setSavedMsg(null), 2500)
  }

  function handleToggleEnabled() {
    if (!canEdit) return
    setErrorMsg(null)
    const nextEnabled = !state.enabled
    startTransition(async () => {
      try {
        const next = await setCustomerPortalPlatformEnabled(
          nextEnabled,
          note.trim() || undefined,
        )
        setState(next)
        showSaved()
      } catch (err) {
        setErrorMsg(err instanceof Error ? err.message : String(err))
      }
    })
  }

  function handleSaveMaxMode() {
    if (!canEdit) return
    setErrorMsg(null)
    startTransition(async () => {
      try {
        const next = await setCustomerPortalPlatformMaxMode(
          maxMode as 'share_only' | 'portal',
          note.trim() || undefined,
        )
        setState(next)
        setMaxMode(next.max_mode)
        showSaved()
      } catch (err) {
        setErrorMsg(err instanceof Error ? err.message : String(err))
      }
    })
  }

  const enabled = state.enabled

  return (
    <div className="space-y-8">
      <section className="bg-white rounded-2xl border border-gray-100 p-6 shadow-sm space-y-4">
        <div className="flex items-start justify-between gap-4">
          <div>
            <h2 className="text-base font-semibold text-gray-900">
              Kill switch de plataforma
            </h2>
            <p className="text-sm text-gray-500 mt-1 max-w-2xl">
              Desactiva el portal client a tota la plataforma. Els tenants no poden crear shares
              ni atorgar accés mentre estigui apagat.
            </p>
          </div>
          <div className="flex items-center gap-3 shrink-0">
            {savedMsg && <span className="text-sm text-green-600 font-medium">{savedMsg}</span>}
            <button
              type="button"
              onClick={handleToggleEnabled}
              disabled={isPending || !canEdit}
              className={`relative inline-flex h-6 w-11 items-center rounded-full transition-colors disabled:opacity-50 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-offset-2 ${
                enabled ? 'bg-indigo-500' : 'bg-gray-200'
              }`}
              aria-pressed={enabled}
              title={canEdit ? 'Kill switch portal client' : 'Només lectura'}
            >
              <span
                className={`inline-block h-4 w-4 transform rounded-full bg-white transition ${
                  enabled ? 'translate-x-6' : 'translate-x-1'
                }`}
              />
            </button>
          </div>
        </div>

        <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
          <Stat
            label="Estat"
            value={enabled ? 'Actiu' : 'Desactivat'}
          />
          <Stat
            label="max_mode"
            value={String(state.max_mode ?? '—')}
          />
          <Stat
            label="security_version"
            value={String(state.security_version ?? '—')}
          />
          <Stat
            label="Nota actual"
            value={state.note?.trim() ? state.note : '—'}
          />
        </div>

        {canEdit && (
          <div className="flex flex-wrap items-end gap-4 pt-2 border-t border-gray-100">
            <label className="text-sm text-gray-700">
              max_mode
              <select
                value={maxMode}
                onChange={(e) => setMaxMode(e.target.value)}
                className="mt-1 block w-44 rounded-md border border-gray-200 px-2 py-1.5 text-sm"
              >
                {MAX_MODES.map((m) => (
                  <option key={m} value={m}>{m}</option>
                ))}
              </select>
            </label>
            <label className="text-sm text-gray-700 grow min-w-[200px]">
              Nota (opcional)
              <input
                type="text"
                value={note}
                onChange={(e) => setNote(e.target.value)}
                className="mt-1 block w-full rounded-md border border-gray-200 px-2 py-1.5 text-sm"
                placeholder="Motiu del canvi"
              />
            </label>
            <button
              type="button"
              onClick={handleSaveMaxMode}
              disabled={isPending}
              className="rounded-md bg-indigo-600 px-3 py-2 text-sm font-medium text-white hover:bg-indigo-500 disabled:opacity-50"
            >
              Desar max_mode
            </button>
          </div>
        )}

        {errorMsg && <p className="text-sm text-red-600">{errorMsg}</p>}
      </section>
    </div>
  )
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-lg bg-gray-50 px-3 py-2">
      <p className="text-[11px] text-gray-500">{label}</p>
      <p className="text-lg font-semibold tabular-nums text-gray-900 truncate" title={value}>
        {value}
      </p>
    </div>
  )
}
