'use client'

import { useState, useTransition } from 'react'
import {
  updateFieldMediaPlatformSettings,
  type FieldMediaPlatformSettings,
} from '@/app/admin/actions/field-media-settings'

export function AdminFieldMediaSettings({
  initialSettings,
}: {
  initialSettings: FieldMediaPlatformSettings
}) {
  const [settings, setSettings] = useState(initialSettings)
  const [pending, startTransition] = useTransition()
  const [message, setMessage] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  function save() {
    setMessage(null)
    setError(null)
    startTransition(async () => {
      try {
        const next = await updateFieldMediaPlatformSettings(settings)
        setSettings(next)
        setMessage('Desat')
      } catch (err) {
        setError(err instanceof Error ? err.message : 'Error')
      }
    })
  }

  return (
    <div className="space-y-6 rounded-xl border border-gray-200 bg-white p-6">
      <div className="space-y-3">
        <label className="flex items-center gap-2 text-sm font-medium">
          <input
            type="checkbox"
            checked={settings.compression.enabled}
            onChange={(e) =>
              setSettings((s) => ({
                ...s,
                compression: { ...s.compression, enabled: e.target.checked },
              }))
            }
          />
          Compressió d&apos;imatges activada
        </label>

        <div className="space-y-1">
          <label className="text-sm font-medium" htmlFor="level">
            Nivell (fallback plataforma)
          </label>
          <select
            id="level"
            className="w-full rounded-md border border-gray-300 px-3 py-2 text-sm"
            value={settings.compression.level}
            onChange={(e) =>
              setSettings((s) => ({
                ...s,
                compression: {
                  ...s.compression,
                  level: e.target.value as FieldMediaPlatformSettings['compression']['level'],
                },
              }))
            }
          >
            <option value="aggressive">Agressiu</option>
            <option value="balanced">Equilibrat</option>
            <option value="original">Original + derivada light</option>
          </select>
        </div>

        <div className="space-y-1">
          <label className="text-sm font-medium" htmlFor="upload_mode">
            Mode d&apos;upload per defecte (tenant)
          </label>
          <select
            id="upload_mode"
            className="w-full rounded-md border border-gray-300 px-3 py-2 text-sm"
            value={settings.upload_mode_default}
            onChange={(e) =>
              setSettings((s) => ({
                ...s,
                upload_mode_default: e.target.value === 'queue' ? 'queue' : 'direct',
              }))
            }
          >
            <option value="direct">Pujada directa</option>
            <option value="queue">Cua offline</option>
          </select>
          <p className="text-xs text-gray-500">
            La cua és local al dispositiu del tècnic; això només defineix el default inicial.
          </p>
        </div>
      </div>

      <div className="flex items-center gap-3">
        <button
          type="button"
          onClick={save}
          disabled={pending}
          className="rounded-md bg-indigo-600 px-4 py-2 text-sm font-medium text-white hover:bg-indigo-700 disabled:opacity-50"
        >
          {pending ? 'Desant…' : 'Desar'}
        </button>
        {message && <span className="text-sm text-green-700">{message}</span>}
        {error && <span className="text-sm text-red-600">{error}</span>}
      </div>
    </div>
  )
}
