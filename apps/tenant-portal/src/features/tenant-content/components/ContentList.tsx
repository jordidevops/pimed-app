import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { Plus, FileText, Megaphone } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { useTenantContentItems } from '../api/useTenantContentItems'
import { channelBadge } from '../utils/contentPayloadMapper'
import type { ContentEntryContext, ContentListFilters } from '../api/tenantContentTypes'

interface Props {
  tenantId: string
  entryContext: ContentEntryContext
  canManage: boolean
  publicSiteId?: string
  newPath: string
  editPath: (id: string) => string
}

function badgeClass(kind: 'employee' | 'public' | 'dual') {
  if (kind === 'dual') return 'bg-violet-100 text-violet-700'
  if (kind === 'public') return 'bg-green-100 text-green-700'
  return 'bg-blue-100 text-blue-700'
}

export function ContentList({
  tenantId,
  entryContext,
  canManage,
  publicSiteId,
  newPath,
  editPath,
}: Props) {
  const { t } = useTranslation('tenant-content')

  const filters: ContentListFilters = publicSiteId ? { public_site_id: publicSiteId } : {}

  const { data: items = [], isLoading } = useTenantContentItems(tenantId, filters)

  const visibleItems = items.filter((item) => {
    if (entryContext === 'public') {
      return item.public_channel_enabled && (!publicSiteId || item.public_site_id === publicSiteId)
    }
    return item.employee_channel_enabled
  })

  return (
    <section className="rounded-2xl border bg-card p-6 space-y-4">
      <div className="flex items-start justify-between gap-4">
        <div>
          <h2 className="text-base font-semibold">
            {entryContext === 'employee'
              ? t('tenant_content.list.employee_title', 'Contingut portal empleat')
              : t('tenant_content.list.public_title', 'Pàgines web')}
          </h2>
          <p className="text-sm text-muted-foreground mt-0.5">
            {t('tenant_content.list.subtitle', '{{count}} elements', { count: visibleItems.length })}
          </p>
        </div>
        {canManage && (
          <Button size="sm" variant="outline" asChild>
            <Link to={newPath}>
              <Plus className="h-4 w-4 mr-1.5" />
              {t('tenant_content.list.new', 'Nou')}
            </Link>
          </Button>
        )}
      </div>

      {isLoading ? (
        <div className="space-y-2">
          {[1, 2, 3].map((i) => (
            <div key={i} className="h-14 rounded-xl bg-muted animate-pulse" />
          ))}
        </div>
      ) : visibleItems.length === 0 ? (
        <p className="text-sm text-muted-foreground py-8 text-center">
          {t('tenant_content.list.empty', 'Encara no hi ha contingut.')}
        </p>
      ) : (
        <ul className="divide-y rounded-xl border overflow-hidden">
          {visibleItems.map((item) => {
            const badge = channelBadge(item)
            const Icon = item.content_type === 'announcement' ? Megaphone : FileText
            return (
              <li key={item.id}>
                <Link
                  to={canManage ? editPath(item.id) : '#'}
                  className="flex items-center gap-3 px-4 py-3 hover:bg-muted/40 transition-colors"
                >
                  <Icon className="h-4 w-4 text-muted-foreground shrink-0" />
                  <div className="min-w-0 flex-1">
                    <p className="text-sm font-medium truncate">{item.title}</p>
                    <p className="text-xs text-muted-foreground font-mono">/{item.slug}</p>
                  </div>
                  <span className={`text-xs px-2 py-0.5 rounded-full font-medium ${badgeClass(badge)}`}>
                    {badge === 'dual'
                      ? t('tenant_content.badges.dual', 'Dual')
                      : badge === 'public'
                        ? t('tenant_content.badges.public', 'Públic')
                        : t('tenant_content.badges.employee', 'Intern')}
                  </span>
                  <span
                    className={`text-xs px-2 py-0.5 rounded-full ${
                      item.status === 'published'
                        ? 'bg-green-100 text-green-700'
                        : item.status === 'archived'
                          ? 'bg-gray-100 text-gray-500'
                          : 'bg-amber-100 text-amber-700'
                    }`}
                  >
                    {item.status}
                  </span>
                </Link>
              </li>
            )
          })}
        </ul>
      )}
    </section>
  )
}
