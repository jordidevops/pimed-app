import { getPlatformSecrets, logPlatformSecretRotation } from '@/app/admin/actions/security-secrets'
import { Badge } from '@/components/ui/badge'
import { PlatformSecretRotationForm } from '@/components/dashboard/PlatformSecretRotationForm'

function statusVariant(status: string): 'default' | 'secondary' | 'destructive' | 'outline' {
  if (status === 'active') return 'default'
  if (status === 'rotating') return 'secondary'
  if (status === 'deprecated') return 'destructive'
  return 'outline'
}

function formatDate(iso: string | null) {
  if (!iso) return '—'
  return new Date(iso).toLocaleDateString('ca-ES', {
    day: '2-digit',
    month: 'short',
    year: 'numeric',
  })
}

export default async function PlatformSecretsPage() {
  const secrets = await getPlatformSecrets()

  const dueSoon = secrets.filter(
    (s) => s.rotation_due_at && new Date(s.rotation_due_at) < new Date(Date.now() + 30 * 86400000),
  )

  return (
    <div className="space-y-8">
      <div>
        <h1 className="text-2xl font-bold">Secrets de plataforma</h1>
        <p className="text-sm text-muted-foreground mt-1">
          Metadades de rotació. Els valors reals viuen als secrets d&apos;Edge Functions de Supabase.
        </p>
      </div>

      {dueSoon.length > 0 && (
        <div className="rounded-lg border border-amber-200 bg-amber-50 dark:bg-amber-950/30 p-4 text-sm">
          <strong>{dueSoon.length}</strong> secret(s) amb rotació prevista en menys de 30 dies.
        </div>
      )}

      <div className="rounded-lg border overflow-hidden">
        <table className="w-full text-sm">
          <thead className="bg-muted/50">
            <tr>
              <th className="text-left p-3 font-medium">Clau</th>
              <th className="text-left p-3 font-medium">Categoria</th>
              <th className="text-left p-3 font-medium">Versió</th>
              <th className="text-left p-3 font-medium">Estat</th>
              <th className="text-left p-3 font-medium">Última rotació</th>
              <th className="text-left p-3 font-medium">Propera rotació</th>
            </tr>
          </thead>
          <tbody>
            {secrets.map((s) => (
              <tr key={s.id} className="border-t">
                <td className="p-3">
                  <div className="font-mono text-xs">{s.secret_key}</div>
                  {s.description && (
                    <div className="text-muted-foreground text-xs mt-0.5">{s.description}</div>
                  )}
                </td>
                <td className="p-3">{s.category}</td>
                <td className="p-3">v{s.key_version}</td>
                <td className="p-3">
                  <Badge variant={statusVariant(s.rotation_status)}>{s.rotation_status}</Badge>
                </td>
                <td className="p-3">{formatDate(s.last_rotated_at)}</td>
                <td className="p-3">{formatDate(s.rotation_due_at)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <PlatformSecretRotationForm action={logPlatformSecretRotation} secretKeys={secrets.map((s) => s.secret_key)} />
    </div>
  )
}
