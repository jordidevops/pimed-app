import { useTranslation } from 'react-i18next'
import { cn } from '@/lib/utils'
import { PINNED_MAX_HEIGHT_CLASS } from './sidebarNavSchema'
import { resolveSidebarNav, type LabelResolvers, type NavGateContext, type ResolvedNavItem } from './resolveNav'
import type { SidebarNavV1 } from './sidebarNavSchema'

function itemClass(opts: { emphasis: 'default' | 'accent' }) {
  if (opts.emphasis === 'accent') return 'tp-nav-item tp-nav-item-accent'
  return 'tp-nav-item'
}

function PreviewItem({ item }: { item: ResolvedNavItem }) {
  if (item.kind === 'theme') {
    return (
      <div
        className={cn(
          itemClass({ emphasis: item.emphasis }),
          'pointer-events-none opacity-90',
        )}
      >
        {item.showIcon ? (
          <item.icon className="h-5 w-5 shrink-0" />
        ) : (
          <span className="h-5 w-5 shrink-0" aria-hidden />
        )}
        <span>{item.label}</span>
      </div>
    )
  }
  const Icon = item.icon
  return (
    <div className={cn(itemClass({ emphasis: item.emphasis }), 'pointer-events-none')}>
      {item.showIcon ? <Icon className="h-5 w-5 shrink-0" /> : <span className="h-5 w-5 shrink-0" aria-hidden />}
      <span>{item.label}</span>
    </div>
  )
}

/** Read-only mini sidebar preview of a draft layout (as it would look after save). */
export function SidebarMenuPreview({
  layout,
  ctx,
  labels,
  className,
}: {
  layout: SidebarNavV1
  ctx: NavGateContext
  labels: LabelResolvers
  className?: string
}) {
  const { t } = useTranslation('common')
  const resolved = resolveSidebarNav(layout, ctx, labels)

  return (
    <div
      className={cn(
        'flex h-[min(28rem,70vh)] w-64 flex-col overflow-hidden rounded-xl border border-border bg-card shadow-lg',
        className,
      )}
      aria-label={t('sidebar_editor.preview_label', 'Previsualització del menú')}
    >
      <div className="flex items-center gap-2 border-b border-border px-3 py-2.5">
        <div className="h-6 w-6 rounded-md bg-indigo-600" aria-hidden />
        <span className="text-sm font-bold text-foreground">Portal de Clients</span>
      </div>

      <div className="flex min-h-0 flex-1 flex-col gap-2 px-2 py-2">
        {resolved.pinned && (
          <div
            className={cn(
              'shrink-0 overflow-y-auto border-b border-border pb-2',
              PINNED_MAX_HEIGHT_CLASS,
            )}
          >
            <ul className="space-y-0.5">
              {resolved.pinned.items.map((item) => (
                <li key={item.id}>
                  <PreviewItem item={item} />
                </li>
              ))}
            </ul>
          </div>
        )}

        <div className="min-h-0 flex-1 overflow-y-auto">
          <div className="space-y-3">
            {resolved.groups.length === 0 && !resolved.pinned ? (
              <p className="px-2 py-4 text-center text-xs text-muted-foreground">
                {t('sidebar_editor.preview_empty', 'Menú buit (s\'aplicaria el fallback).')}
              </p>
            ) : (
              resolved.groups.map((group) => (
                <div key={group.id}>
                  {group.label && (
                    <p className="mb-1 px-3 text-[10px] font-semibold uppercase tracking-widest text-muted-foreground/70">
                      {group.label}
                    </p>
                  )}
                  <ul className="space-y-0.5">
                    {group.items.map((item) => (
                      <li key={item.id}>
                        <PreviewItem item={item} />
                      </li>
                    ))}
                  </ul>
                </div>
              ))
            )}
          </div>
        </div>
      </div>

      <div className="border-t border-border px-3 py-2 text-[10px] text-muted-foreground">
        {t('sidebar_editor.preview_footer', 'Així es veuria si desessis ara')}
      </div>
    </div>
  )
}
