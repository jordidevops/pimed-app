import { useTranslation } from 'react-i18next'
import { Link2 } from 'lucide-react'
import { useEmployeeExternalMappings } from '../import/useEmployeeImport'

export function EmployeeExternalMappingsSection({ employeeId }: { employeeId: string }) {
  const { t } = useTranslation('employees')
  const { data: mappings = [], isLoading, error } = useEmployeeExternalMappings(employeeId)

  return (
    <div className="space-y-3 pt-4 border-t border-border">
      <div className="flex items-center gap-2">
        <Link2 className="h-4 w-4 text-muted-foreground" aria-hidden />
        <h3 className="text-sm font-semibold">
          {t('employees.mappings.title', 'Enllaços externs')}
        </h3>
      </div>
      <p className="text-xs text-muted-foreground">
        {t(
          'employees.mappings.hint',
          'IDs a Holded, PayFit, CSV o gestoria. Només lectura; es creen en importar.',
        )}
      </p>

      {isLoading ? (
        <p className="text-sm text-muted-foreground">{t('employees.mappings.loading', 'Carregant…')}</p>
      ) : error ? (
        <p className="text-sm text-destructive">
          {t('employees.mappings.error', 'No s\'han pogut carregar els enllaços')}
        </p>
      ) : mappings.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          {t('employees.mappings.empty', 'Sense enllaços externs')}
        </p>
      ) : (
        <ul className="space-y-2">
          {mappings.map((m) => (
            <li
              key={m.id}
              className="flex flex-wrap items-baseline justify-between gap-2 text-sm rounded-md border border-border px-3 py-2"
            >
              <span className="font-medium capitalize">{m.provider}</span>
              <span className="font-mono text-muted-foreground">{m.external_id}</span>
              {m.last_synced_at ? (
                <span className="text-xs text-muted-foreground w-full">
                  {t('employees.mappings.last_sync', 'Últim sync: {{date}}', {
                    date: new Date(m.last_synced_at).toLocaleString(),
                  })}
                </span>
              ) : null}
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
