'use client'

import { useTransition } from 'react'
import { Button } from '@/components/ui/button'

export function PlatformSecretRotationForm({
  action,
  secretKeys,
}: {
  action: (formData: FormData) => Promise<void>
  secretKeys: string[]
}) {
  const [pending, startTransition] = useTransition()

  return (
    <form
      className="rounded-lg border p-4 space-y-4 max-w-lg"
      action={(fd) => startTransition(() => action(fd))}
    >
      <h2 className="font-semibold">Registrar rotació completada</h2>
      <p className="text-xs text-muted-foreground">
        Després de rotar el valor al Dashboard de Supabase, registra-ho aquí.
      </p>
      <div className="space-y-2">
        <label className="text-sm font-medium" htmlFor="secret_key">Secret</label>
        <select
          id="secret_key"
          name="secret_key"
          required
          className="w-full rounded-md border px-3 py-2 text-sm bg-background"
        >
          <option value="">Selecciona…</option>
          {secretKeys.map((k) => (
            <option key={k} value={k}>{k}</option>
          ))}
        </select>
      </div>
      <div className="space-y-2">
        <label className="text-sm font-medium" htmlFor="rotated_by">Rotat per</label>
        <input
          id="rotated_by"
          name="rotated_by"
          type="text"
          placeholder="email o nom"
          className="w-full rounded-md border px-3 py-2 text-sm bg-background"
        />
      </div>
      <div className="space-y-2">
        <label className="text-sm font-medium" htmlFor="notes">Notes</label>
        <textarea
          id="notes"
          name="notes"
          rows={2}
          className="w-full rounded-md border px-3 py-2 text-sm bg-background"
        />
      </div>
      <Button type="submit" disabled={pending}>
        {pending ? 'Desant…' : 'Marcar com a rotat'}
      </Button>
    </form>
  )
}
