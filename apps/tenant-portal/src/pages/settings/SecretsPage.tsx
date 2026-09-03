import { useQuery } from '@tanstack/react-query'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { KeyRound, ExternalLink } from 'lucide-react'
import { useTenant } from '@/contexts/TenantContext'
import {
  listTenantSecrets,
  listSecretRotationLog,
  secretSettingsLink,
} from '@/features/secrets/api/secretsService'
import { Badge } from '@/components/ui/badge'

function formatDate(iso: string | null) {
  if (!iso) return '—'
  return new Date(iso).toLocaleDateString('ca-ES', {
    day: '2-digit',
    month: 'short',
    year: 'numeric',
  })
}

function isDueSoon(iso: string | null) {
  if (!iso) return false
  return new Date(iso) < new Date(Date.now() + 30 * 86400000)
}

export function SecretsPage() {
  const { t } = useTranslation(['settings'])
  const { activeTenant, activeRole } = useTenant()
  const tenantId = activeTenant?.id

  const canManage = activeRole === 'owner' || activeRole === 'manager'

  const { data: secrets = [], isLoading } = useQuery({
    queryKey: ['tenant-secrets', tenantId],
    queryFn: () => listTenantSecrets(tenantId!),
    enabled: !!tenantId && canManage,
  })

  const { data: rotationLog = [] } = useQuery({
    queryKey: ['secret-rotation-log', tenantId],
    queryFn: () => listSecretRotationLog(tenantId!),
    enabled: !!tenantId && canManage,
  })

  if (!canManage) {
    return (
      <p className="text-sm text-muted-foreground">
        {t('secrets.forbidden', 'Només owners i managers poden veure els secrets configurats.')}
      </p>
    )
  }

  return (
    <div className="space-y-8">
      <div>
        <h2 className="text-lg font-semibold flex items-center gap-2">
          <KeyRound className="h-5 w-5" />
          {t('secrets.title', 'Secrets i integracions')}
        </h2>
        <p className="text-sm text-muted-foreground mt-1">
          {t('secrets.subtitle', 'Metadades dels secrets BYO. Els valors mai es mostren aquí.')}
        </p>
      </div>

      {isLoading ? (
        <div className="animate-pulse h-32 rounded-2xl border bg-muted/30" />
      ) : secrets.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          {t('secrets.empty', 'Cap secret configurat. Configura integracions a les seccions corresponents.')}
        </p>
      ) : (
        <div className="rounded-2xl border overflow-hidden">
          <table className="w-full text-sm">
            <thead className="bg-muted/40">
              <tr>
                <th className="text-left p-3 font-medium">{t('secrets.col_type', 'Tipus')}</th>
                <th className="text-left p-3 font-medium">{t('secrets.col_provider', 'Proveïdor')}</th>
                <th className="text-left p-3 font-medium">{t('secrets.col_version', 'Versió')}</th>
                <th className="text-left p-3 font-medium">{t('secrets.col_due', 'Propera rotació')}</th>
                <th className="p-3" />
              </tr>
            </thead>
            <tbody>
              {secrets.map((s) => {
                const link = secretSettingsLink(s.secret_type)
                const dueSoon = isDueSoon(s.rotation_due_at)
                return (
                  <tr key={s.id} className="border-t">
                    <td className="p-3">
                      <div className="font-medium">{s.label ?? s.secret_type}</div>
                      <div className="text-xs text-muted-foreground">{s.secret_type}</div>
                    </td>
                    <td className="p-3 font-mono text-xs">{s.provider}</td>
                    <td className="p-3">v{s.key_version}</td>
                    <td className="p-3">
                      {dueSoon ? (
                        <Badge variant="destructive">{formatDate(s.rotation_due_at)}</Badge>
                      ) : (
                        formatDate(s.rotation_due_at)
                      )}
                    </td>
                    <td className="p-3 text-right">
                      {link && (
                        <Link
                          to={link}
                          className="inline-flex items-center gap-1 text-xs text-primary hover:underline"
                        >
                          {t('secrets.manage', 'Gestionar')}
                          <ExternalLink className="h-3 w-3" />
                        </Link>
                      )}
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      )}

      {rotationLog.length > 0 && (
        <section className="space-y-3">
          <h3 className="text-sm font-semibold">{t('secrets.rotation_history', 'Historial de rotacions')}</h3>
          <ul className="text-sm space-y-2">
            {rotationLog.map((r) => (
              <li key={r.id} className="rounded-lg border px-3 py-2 text-muted-foreground">
                <span className="text-foreground font-medium">{r.secret_type}</span>
                {' · '}
                v{r.old_key_version} → v{r.new_key_version}
                {' · '}
                {formatDate(r.created_at)}
              </li>
            ))}
          </ul>
        </section>
      )}
    </div>
  )
}
