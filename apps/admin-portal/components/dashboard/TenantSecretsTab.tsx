'use client'

import { useTransition } from 'react'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { adminRevokeTenantSecret, adminRotateTenantFieldDek } from '@/app/admin/actions/security-secrets'
import type { TenantSecretMeta } from '@/app/admin/actions/security-secrets'

function formatDate(iso: string | null) {
  if (!iso) return '—'
  return new Date(iso).toLocaleDateString('ca-ES')
}

export function TenantSecretsTab({
  tenantId,
  secrets,
}: {
  tenantId: string
  secrets: TenantSecretMeta[]
}) {
  const [pending, startTransition] = useTransition()

  const handleRevoke = (secretType: string, provider: string) => {
    if (secretType === 'tenant_field_dek') return
    if (!confirm('Revocar aquest secret? El tenant haurà de configurar-ne un de nou.')) return
    startTransition(async () => {
      await adminRevokeTenantSecret(tenantId, secretType, provider)
    })
  }

  const handleRotateDek = () => {
    if (
      !confirm(
        'Rotar la DEK del tenant? Es re-xifraran tots els IBAN/NSS. Només platform admin.',
      )
    ) {
      return
    }
    startTransition(async () => {
      await adminRotateTenantFieldDek(tenantId)
    })
  }

  if (secrets.length === 0) {
    return (
      <p className="text-sm text-muted-foreground py-4">
        Aquest tenant no té secrets BYO registrats.
      </p>
    )
  }

  return (
    <div className="rounded-lg border overflow-hidden">
      <table className="w-full text-sm">
        <thead className="bg-muted/50">
          <tr>
            <th className="text-left p-3">Tipus</th>
            <th className="text-left p-3">Proveïdor</th>
            <th className="text-left p-3">Versió</th>
            <th className="text-left p-3">Estat</th>
            <th className="text-left p-3">Propera rotació</th>
            <th className="p-3" />
          </tr>
        </thead>
        <tbody>
          {secrets.map((s) => {
            const isFieldDek = s.secret_type === 'tenant_field_dek'
            return (
            <tr key={s.id} className="border-t">
              <td className="p-3">
                {s.secret_type}
                {isFieldDek ? (
                  <span className="ml-2 text-xs text-muted-foreground">
                    (PII envelope — no revocar)
                  </span>
                ) : null}
              </td>
              <td className="p-3 font-mono text-xs">{s.provider}</td>
              <td className="p-3">v{s.key_version}</td>
              <td className="p-3">
                <Badge variant={s.rotation_status === 'active' ? 'default' : 'secondary'}>
                  {s.rotation_status}
                </Badge>
              </td>
              <td className="p-3">{formatDate(s.rotation_due_at)}</td>
              <td className="p-3 text-right">
                {s.rotation_status === 'active' && !isFieldDek && (
                  <Button
                    size="sm"
                    variant="destructive"
                    disabled={pending}
                    onClick={() => handleRevoke(s.secret_type, s.provider)}
                  >
                    Revocar
                  </Button>
                )}
                {isFieldDek ? (
                  <Button
                    size="sm"
                    variant="outline"
                    disabled={pending}
                    onClick={handleRotateDek}
                  >
                    Rotar DEK
                  </Button>
                ) : null}
              </td>
            </tr>
            )
          })}
        </tbody>
      </table>
    </div>
  )
}
