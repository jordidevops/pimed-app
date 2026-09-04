import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { Settings2, Building2 } from 'lucide-react'
import { useSidebarNav } from '@/features/sidebar-nav'
import { Button } from '@/components/ui/button'

export function AppIndexPage() {
  const { t } = useTranslation('common')
  const { launcherGroups, gatesLoading, canEditTenant, tenantId } = useSidebarNav()

  if (!tenantId) {
    return (
      <div className="mx-auto max-w-3xl p-6">
        <p className="text-sm text-muted-foreground">
          {t('app_index.need_tenant', 'Selecciona una organització per veure l\'índex.')}
        </p>
      </div>
    )
  }

  return (
    <div className="mx-auto max-w-3xl p-6 space-y-8">
      <header className="space-y-3">
        <h1 className="text-2xl font-bold tracking-tight text-foreground">
          {t('app_index.title', 'Índex de l\'aplicació')}
        </h1>
        <p className="text-sm text-muted-foreground max-w-prose">
          {t(
            'app_index.subtitle',
            'Totes les seccions i mòduls als quals tens accés. El menú lateral pot amagar-ne alguns; aquí sempre els trobaràs.',
          )}
        </p>
        <div className="flex flex-wrap gap-2 pt-1">
          <Button asChild variant="default" size="sm">
            <Link to="/app/sidebar">
              <Settings2 className="h-4 w-4" />
              {t('app_index.customize_mine', 'Personalitzar el meu menú')}
            </Link>
          </Button>
          {canEditTenant && (
            <Button asChild variant="outline" size="sm">
              <Link to="/app/sidebar?scope=tenant">
                <Building2 className="h-4 w-4" />
                {t('app_index.customize_org', 'Menú de l\'organització')}
              </Link>
            </Button>
          )}
        </div>
      </header>

      {gatesLoading ? (
        <div className="space-y-4 animate-pulse" aria-busy="true">
          {[1, 2, 3].map((i) => (
            <div key={i} className="h-24 rounded-xl bg-muted" />
          ))}
        </div>
      ) : (
        <div className="space-y-8">
          {launcherGroups.map((group) => (
            <section key={group.id} className="space-y-3">
              <h2 className="text-xs font-semibold uppercase tracking-widest text-muted-foreground">
                {group.label ?? t('app_index.untitled_section', 'Inici')}
              </h2>
              <ul className="divide-y divide-border rounded-xl border border-border bg-card">
                {group.items.map((item) => {
                  const Icon = item.icon
                  if (item.kind === 'theme' || !item.to) {
                    return (
                      <li key={item.id} className="flex items-center gap-3 px-4 py-3 text-sm text-muted-foreground">
                        <Icon className="h-5 w-5 shrink-0" />
                        <span>{item.label}</span>
                        <span className="ml-auto text-xs">
                          {t('app_index.sidebar_only', 'Només al menú lateral')}
                        </span>
                      </li>
                    )
                  }
                  return (
                    <li key={item.id}>
                      <Link
                        to={item.to}
                        className="flex items-center gap-3 px-4 py-3 text-sm font-medium text-foreground transition-colors hover:bg-indigo-50 hover:text-indigo-700 dark:hover:bg-indigo-950/50 dark:hover:text-indigo-200"
                      >
                        <Icon className="h-5 w-5 shrink-0 text-muted-foreground" />
                        <span>{item.label}</span>
                      </Link>
                    </li>
                  )
                })}
              </ul>
            </section>
          ))}
        </div>
      )}
    </div>
  )
}
