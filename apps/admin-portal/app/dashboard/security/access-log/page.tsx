import { getSecretAccessLog } from '@/app/admin/actions/security-secrets'

function formatDate(iso: string) {
  return new Date(iso).toLocaleString('ca-ES')
}

export default async function SecretAccessLogPage() {
  const logs = await getSecretAccessLog({ limit: 200 })

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold">Activitat de secrets</h1>
        <p className="text-sm text-muted-foreground mt-1">
          Lectures de secrets de tenant (sense valors). Útil per detectar anomalies.
        </p>
      </div>

      <div className="rounded-lg border overflow-x-auto">
        <table className="w-full text-sm min-w-[800px]">
          <thead className="bg-muted/50">
            <tr>
              <th className="text-left p-3 font-medium">Data</th>
              <th className="text-left p-3 font-medium">Tenant</th>
              <th className="text-left p-3 font-medium">Tipus</th>
              <th className="text-left p-3 font-medium">Proveïdor</th>
              <th className="text-left p-3 font-medium">Funció</th>
              <th className="text-left p-3 font-medium">Motiu</th>
            </tr>
          </thead>
          <tbody>
            {logs.length === 0 ? (
              <tr>
                <td colSpan={6} className="p-6 text-center text-muted-foreground">
                  Cap accés registrat encara.
                </td>
              </tr>
            ) : (
              logs.map((row) => (
                <tr key={`${row.id}-${row.created_at}`} className="border-t">
                  <td className="p-3 whitespace-nowrap">{formatDate(row.created_at)}</td>
                  <td className="p-3 font-mono text-xs">{row.tenant_id?.slice(0, 8) ?? '—'}…</td>
                  <td className="p-3">{row.secret_type}</td>
                  <td className="p-3 text-xs">{row.provider ?? '—'}</td>
                  <td className="p-3 font-mono text-xs">{row.accessed_by_fn}</td>
                  <td className="p-3 text-xs text-muted-foreground">{row.access_reason ?? '—'}</td>
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>
    </div>
  )
}
