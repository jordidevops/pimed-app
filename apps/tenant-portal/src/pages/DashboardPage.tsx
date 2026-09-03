import { useAuth } from '../contexts/AuthContext'
import { useTenant } from '../contexts/TenantContext'
import { Navigate } from 'react-router-dom'
import { useIsFieldService } from '@/hooks/useSectorLabel'
import { useNotes } from '../hooks/useNotes'
import { useTranslation } from 'react-i18next'
import { CalendarWidget } from '../features/calendar'
import { DeadLetterAlertWidget } from '../features/email'
import {
  OperationsAlertBanner,
} from '../features/operations'
import { OpenTasksWidget } from '../features/entity-timeline/components/OpenTasksWidget'
import { TenantActivityWidget } from '../features/entity-timeline/components/TenantActivityWidget'
import { useTenantFeatures } from '../features/entity-timeline/api/useTenantFeatures'
import { useMarkOperationsDashboardVisit } from '../hooks/useMarkOperationsDashboardVisit'

export function DashboardPage() {
  const { t, i18n } = useTranslation('common')
  const locale = i18n.resolvedLanguage?.startsWith('ca')
    ? 'ca-ES'
    : i18n.resolvedLanguage?.startsWith('es')
      ? 'es-ES'
      : 'en-US'
  const { user } = useAuth()
  const { tenants, tenantsLoading, selectedTenantId, selectedSiteId, activeTenant, activeRole, sites } = useTenant()
  const isFieldService = useIsFieldService()
  const canViewOperations = activeRole === 'owner' || activeRole === 'manager'
  const { data: features } = useTenantFeatures()

  useMarkOperationsDashboardVisit(user?.id, activeTenant?.id)

  const { data: notes = [], isLoading: notesLoading } = useNotes(user?.id, selectedTenantId, selectedSiteId)

  if (!tenantsLoading && isFieldService) {
    return <Navigate to="/field/today" replace />
  }

  const isMultiTenant = tenants.length > 1
  const tenantLabel = activeTenant?.name ?? (isMultiTenant ? t('dashboard.allTenants', 'Tots els tenants') : t('dashboard.none', '—'))
  const tenantMap = new Map(tenants.map((t) => [t.id, t.name]))
  const siteMap = new Map(sites.map((s) => [s.id, s.name]))
  // Mostrar badge de site quan estem a la Vista Global (selectedSiteId null) i hi ha sites
  const showSiteBadge = selectedTenantId !== null && selectedSiteId === null && sites.length > 1

  return (
    <div className="max-w-4xl mx-auto px-4 py-10 space-y-6">

        {/* Tenant card */}
        {tenantsLoading ? (
          <div className="bg-card rounded-2xl shadow-sm border border-border p-6 animate-pulse">
            <div className="h-4 bg-muted rounded w-24 mb-3" />
            <div className="h-7 bg-muted rounded w-52" />
          </div>
        ) : (
          <div className="bg-card rounded-2xl shadow-sm border border-border p-6">
            <p className="text-xs text-muted-foreground font-medium uppercase tracking-wide mb-1">
              {t('dashboard.organization', 'Organització')}
            </p>
            <h2 className="text-2xl font-bold text-foreground">{tenantLabel}</h2>
            {activeTenant && (
              <p className="text-sm text-muted-foreground mt-1">
                {t('dashboard.plan', 'Pla')}:{' '}
                <span className="font-medium">
                  {activeTenant.plan_display_name ?? activeTenant.plan_name ?? t('dashboard.none', '—')}
                </span>
                {' · '}
                {t('dashboard.role', 'Rol')}:{' '}
                <span className="font-medium capitalize">{activeTenant.role}</span>
              </p>
            )}
          </div>
        )}

        {/* Dead letter alert */}
        <DeadLetterAlertWidget tenantId={selectedTenantId} siteId={selectedSiteId} />

        <OperationsAlertBanner
          userId={user?.id}
          tenantId={activeTenant?.id}
          canView={canViewOperations}
        />

        <OpenTasksWidget tenantId={selectedTenantId} />

        {canViewOperations && features?.entity_timeline_manager_feed !== false && (
          <TenantActivityWidget tenantId={selectedTenantId} />
        )}

        {/* Notes section */}
        <section>
          <div className="flex items-center gap-2 mb-4">
            <h3 className="text-lg font-semibold text-foreground">{t('dashboard.notes', 'Notes')}</h3>
            {notesLoading && (
              <span className="text-sm text-muted-foreground">{t('dashboard.loading', 'Carregant...')}</span>
            )}
          </div>

          {!notesLoading && notes.length === 0 ? (
            <div className="bg-card rounded-2xl border border-dashed border-border p-10 text-center text-muted-foreground">
              {t('dashboard.emptyNotes', 'Sense notes per mostrar.')}
            </div>
          ) : (
            <ul className="space-y-3">
              {notes.map((note) => (
                <li
                  key={note.id}
                  className={`bg-card rounded-2xl border p-5 shadow-sm transition ${
                    note.is_pinned ? 'border-primary/30' : 'border-border'
                  }`}
                >
                  <div className="flex items-start justify-between gap-4">
                    <div className="flex-1 min-w-0">
                      <div className="flex items-center gap-2 flex-wrap mb-1">
                        {note.is_pinned && (
                          <span className="text-xs bg-indigo-50 text-indigo-700 px-2 py-0.5 rounded-full font-medium">
                            {t('dashboard.pinned', '📌 Fixada')}
                          </span>
                        )}
                        {/* Show tenant badge only when viewing all tenants and there are multiple */}
                        {!selectedTenantId && isMultiTenant && (
                          <span className="text-xs bg-muted text-muted-foreground px-2 py-0.5 rounded-full">
                            {tenantMap.get(note.tenant_id) ?? t('dashboard.none', '—')}
                          </span>
                        )}
                        {/* Show site badge when in Vista Global and note belongs to a specific site */}
                        {showSiteBadge && note.site_id && (
                          <span className="text-xs bg-indigo-50 text-indigo-600 dark:bg-indigo-950 dark:text-indigo-300 px-2 py-0.5 rounded-full">
                            {siteMap.get(note.site_id) ?? t('dashboard.none', '—')}
                          </span>
                        )}
                      </div>
                      <p className="font-semibold text-foreground truncate">{note.title}</p>
                      {note.content && (
                        <p className="text-sm text-muted-foreground mt-1 line-clamp-3">{note.content}</p>
                      )}
                    </div>
                    <time
                      className="text-xs text-muted-foreground shrink-0 mt-1"
                      dateTime={note.created_at}
                    >
                      {new Date(note.created_at).toLocaleDateString(locale, {
                        day: 'numeric',
                        month: 'short',
                        year: 'numeric',
                      })}
                    </time>
                  </div>
                </li>
              ))}
            </ul>
          )}
        </section>

        {/* Calendar section */}
        {selectedTenantId ? (
          <section className="bg-card rounded-2xl border border-border p-4 shadow-sm">
            <h3 className="mb-3 text-lg font-semibold text-foreground">
              {t('dashboard.calendar', 'Calendari')}
            </h3>
            <CalendarWidget siteId={selectedSiteId} />
          </section>
        ) : (
          <section className="bg-card rounded-2xl border border-dashed border-border p-6 text-sm text-muted-foreground">
            {t('dashboard.selectTenantForCalendar', 'Selecciona un tenant per veure el calendari.')}
          </section>
        )}
    </div>
  )
}
