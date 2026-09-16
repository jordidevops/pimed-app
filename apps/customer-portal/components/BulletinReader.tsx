'use client'

import { useTranslation } from 'react-i18next'
import { sanitizeClientHtml, plainText } from '@/lib/sanitize'
import { PrintButton } from '@/components/PrintButton'
import { LocaleSwitcher } from '@/components/LocaleSwitcher'
import { PortalFooter } from '@/components/PortalFooter'
import { CookieNotice } from '@/components/CookieNotice'
import type { ActorType } from '@/lib/constants'
import type { PlatformLocale } from '@/lib/locale'
import type { TenantPublicProfile } from '@/lib/constants'

type Props = {
  projection: Record<string, unknown>
  /** Content/bulletin locale (digest line). */
  locale: string
  contentDigest?: string
  actorType: ActorType
  mediaManifest?: unknown
  /** Required for grant media downloads (scoped by report version). */
  reportVersionId?: string
  /** OS / intervention title (same as list); falls back to projection.intervention.title */
  title?: string | null
  uiLocale?: PlatformLocale | string
  allowClientLocaleChange?: boolean
  supportedLocales?: string[]
  accountContactId?: string
  tenantId?: string
  tenantProfile?: TenantPublicProfile | null
}

function checklistItems(projection: Record<string, unknown>): Array<Record<string, unknown>> {
  const raw = projection.checklist_items
  return Array.isArray(raw) ? (raw as Array<Record<string, unknown>>) : []
}

function taskItems(projection: Record<string, unknown>): Array<Record<string, unknown>> {
  const raw = projection.tasks
  return Array.isArray(raw) ? (raw as Array<Record<string, unknown>>) : []
}

function materialItems(projection: Record<string, unknown>): Array<Record<string, unknown>> {
  const raw = projection.materials
  return Array.isArray(raw) ? (raw as Array<Record<string, unknown>>) : []
}

function isTodoChecklistItem(item: Record<string, unknown>): boolean {
  const rt = String(item.response_type ?? '').toLowerCase()
  if (rt === 'checkbox' || rt === 'todo') return true
  // Legacy projections without response_type: boolean without choice label
  if (typeof item.value_bool === 'boolean' && !item.option_label && !item.option_semantics) {
    return true
  }
  return false
}

function groupChecklistByRun(
  items: Array<Record<string, unknown>>,
): Array<{ key: string; title: string | null; items: Array<Record<string, unknown>> }> {
  const order: string[] = []
  const map = new Map<string, { title: string | null; items: Array<Record<string, unknown>> }>()
  for (const item of items) {
    const key = String(item.run_id ?? item.run_name ?? '_default')
    if (!map.has(key)) {
      order.push(key)
      const name = typeof item.run_name === 'string' ? item.run_name.trim() : ''
      map.set(key, { title: name || null, items: [] })
    }
    map.get(key)!.items.push(item)
  }
  return order.map((key) => {
    const g = map.get(key)!
    return { key, title: g.title, items: g.items }
  })
}

function ChecklistTodoMark({ done }: { done: boolean }) {
  if (!done) return null
  return (
    <span
      className="inline-flex h-4 w-4 shrink-0 items-center justify-center rounded-sm bg-[#1b6b5a] text-white"
      aria-hidden
    >
      <svg viewBox="0 0 16 16" className="h-3 w-3" fill="none" stroke="currentColor" strokeWidth="2.2">
        <path d="M3.5 8.5 6.5 11.5 12.5 4.5" strokeLinecap="round" strokeLinejoin="round" />
      </svg>
    </span>
  )
}

function ChecklistBullet() {
  return (
    <span
      className="mt-2 h-1.5 w-1.5 shrink-0 rounded-full bg-[var(--ink)]"
      aria-hidden
    />
  )
}

type TaskStatusKey = 'pending' | 'in_progress' | 'done' | 'blocked'

/** MIME types browsers can typically render in <img> / inline. */
function isInlineBrowserImage(contentType: unknown): boolean {
  const c = String(contentType ?? '')
    .split(';')[0]
    .trim()
    .toLowerCase()
  return (
    c === 'image/jpeg' ||
    c === 'image/jpg' ||
    c === 'image/png' ||
    c === 'image/gif' ||
    c === 'image/webp' ||
    c === 'image/avif'
  )
}

function mediaObjectHref(
  objectKey: string,
  qs: string,
  download?: boolean,
): string {
  const path = objectKey
    .split('/')
    .map((seg) => encodeURIComponent(seg))
    .join('/')
  const params = new URLSearchParams()
  if (qs.startsWith('?')) {
    const existing = new URLSearchParams(qs.slice(1))
    existing.forEach((v, k) => params.set(k, v))
  }
  if (download) params.set('dl', '1')
  const query = params.toString()
  return `/api/media/${path}${query ? `?${query}` : ''}`
}

function mediaDisplayName(m: Record<string, unknown>, index: number): string {
  const fromName =
    typeof m.name === 'string'
      ? m.name.trim()
      : typeof m.file_name === 'string'
        ? m.file_name.trim()
        : ''
  if (fromName) return fromName
  const key = String(m.object_key ?? '')
  const leaf = key.split('/').pop()?.trim()
  if (leaf) return leaf
  return `file-${index + 1}`
}

function normalizeTaskStatus(raw: unknown): TaskStatusKey | null {
  const s = String(raw ?? '').trim().toLowerCase()
  if (s === 'pending' || s === 'todo') return 'pending'
  if (s === 'in_progress' || s === 'in-progress' || s === 'doing') return 'in_progress'
  if (s === 'done' || s === 'completed' || s === 'complete') return 'done'
  if (s === 'blocked') return 'blocked'
  return null
}

function TaskStatusBadge({
  status,
  label,
}: {
  status: TaskStatusKey
  label: string
}) {
  const icon =
    status === 'done' ? (
      <svg viewBox="0 0 16 16" className="h-3 w-3" fill="none" stroke="currentColor" strokeWidth="2.2">
        <path d="M3.5 8.5 6.5 11.5 12.5 4.5" strokeLinecap="round" strokeLinejoin="round" />
      </svg>
    ) : status === 'in_progress' ? (
      <svg viewBox="0 0 16 16" className="h-3 w-3" fill="none" stroke="currentColor" strokeWidth="1.8">
        <circle cx="8" cy="8" r="5.5" />
        <path d="M8 4.5v4l2.5 1.5" strokeLinecap="round" />
      </svg>
    ) : status === 'blocked' ? (
      <svg viewBox="0 0 16 16" className="h-3 w-3" fill="none" stroke="currentColor" strokeWidth="1.8">
        <circle cx="8" cy="8" r="5.5" />
        <path d="M5.5 8h5" strokeLinecap="round" />
      </svg>
    ) : (
      <svg viewBox="0 0 16 16" className="h-3 w-3" fill="none" stroke="currentColor" strokeWidth="1.8">
        <circle cx="8" cy="8" r="5.5" />
      </svg>
    )

  const tone =
    status === 'done'
      ? 'bg-[#e8f2ee] text-[#1b6b5a]'
      : status === 'blocked'
        ? 'bg-[#f4ebe3] text-[#8a4b2e]'
        : status === 'in_progress'
          ? 'bg-[var(--paper)] text-[var(--ink)]'
          : 'bg-[var(--paper)] text-[var(--muted)]'

  return (
    <span
      className={`sans inline-flex shrink-0 items-center gap-1 rounded-full px-2 py-0.5 text-xs ${tone}`}
    >
      {icon}
      {label}
    </span>
  )
}

export function BulletinReader({
  projection,
  locale,
  contentDigest,
  actorType,
  mediaManifest,
  reportVersionId,
  title,
  uiLocale,
  allowClientLocaleChange,
  supportedLocales,
  accountContactId,
  tenantId,
  tenantProfile,
}: Props) {
  const { t } = useTranslation('reader')
  const switcherLocale = uiLocale || locale
  const summaryHtml = sanitizeClientHtml(
    typeof projection.client_summary_html === 'string'
      ? projection.client_summary_html
      : '',
  )
  const tenantName =
    tenantProfile?.display_name?.trim() ||
    (projection.tenant && typeof projection.tenant === 'object'
      ? String((projection.tenant as Record<string, unknown>).name ?? '')
      : '')
  const intervention =
    projection.intervention && typeof projection.intervention === 'object'
      ? (projection.intervention as Record<string, unknown>)
      : null
  const bulletinTitle =
    (typeof intervention?.title === 'string' && intervention.title.trim()) ||
    (typeof title === 'string' && title.trim()) ||
    ''
  const heading =
    bulletinTitle || tenantName || t('fallback_title', 'Intervenció')
  const items = checklistItems(projection)
  const tasks = taskItems(projection)
  const materials = materialItems(projection)
  const media = Array.isArray(mediaManifest)
    ? (mediaManifest as Array<Record<string, unknown>>)
    : []

  const privacyUrl =
    (tenantId
      ? `/legal/privacy_customers?t=${encodeURIComponent(tenantId)}&locale=${encodeURIComponent(locale || 'es')}`
      : null) ||
    tenantProfile?.privacy_url?.trim() ||
    process.env.NEXT_PUBLIC_PRIVACY_INFO_URL
  const showLocaleSwitcher =
    (actorType === 'grant' || actorType === 'share') &&
    allowClientLocaleChange === true &&
    Boolean(accountContactId) &&
    Boolean(tenantId) &&
    Array.isArray(supportedLocales) &&
    supportedLocales.length > 1

  return (
    <main className="mx-auto max-w-2xl px-4 py-8 sm:py-12">
      {actorType === 'staff' && (
        <div className="no-print sans mb-6 rounded-lg border border-[var(--staff)]/30 bg-[#f4ebe3] px-3 py-2 text-sm text-[var(--staff)]">
          {t(
            'staff_banner',
            'Vista de suport (només lectura). Aquesta sessió no compta com a ús del client.',
          )}
        </div>
      )}

      <header className="border-b border-[var(--line)] pb-6">
        <div className="flex items-start justify-between gap-4">
          <div>
            <p className="sans text-xs uppercase tracking-[0.18em] text-[var(--muted)]">
              {t('eyebrow', "Butlletí d'intervenció")}
              {tenantName && bulletinTitle ? ` · ${tenantName}` : ''}
            </p>
            <h1 className="mt-2 text-3xl font-semibold tracking-tight sm:text-4xl">
              {heading}
            </h1>
            {contentDigest && (
              <p className="sans mt-2 text-xs text-[var(--muted)]">
                {t('ref', 'Ref. {{digest}} · {{locale}}', {
                  digest: contentDigest.slice(0, 12),
                  locale,
                })}
              </p>
            )}
          </div>
          {showLocaleSwitcher && accountContactId && tenantId && (
            <LocaleSwitcher
              currentLocale={switcherLocale}
              supportedLocales={supportedLocales!}
              accountContactId={accountContactId}
              tenantId={tenantId}
            />
          )}
        </div>
      </header>

      {summaryHtml && (
        <section className="mt-8">
          <h2 className="sans text-sm font-semibold uppercase tracking-wide text-[var(--accent)]">
            {t('summary', 'Resum')}
          </h2>
          <div
            className="mt-3 prose-sm leading-relaxed"
            dangerouslySetInnerHTML={{ __html: summaryHtml }}
          />
        </section>
      )}

      {items.length > 0 && (
        <section className="mt-10">
          <h2 className="sans text-sm font-semibold uppercase tracking-wide text-[var(--accent)]">
            {t('checklist', 'Checklist')}
          </h2>
          <div className="mt-3 space-y-6">
            {groupChecklistByRun(items).map((group, gi) => (
              <div key={group.key}>
                <h3 className="text-base font-semibold tracking-tight">
                  {group.title ||
                    t('checklist_untitled', 'Checklist {{n}}', { n: gi + 1 })}
                </h3>
                <ul className="mt-3 border-y border-[var(--line)] divide-y divide-[var(--line)]">
                  {group.items.map((item, i) => {
                    const label = String(
                      item.label ??
                        item.title ??
                        item.name ??
                        t('item_fallback', 'Ítem {{n}}', { n: i + 1 }),
                    )
                    const note = plainText(
                      typeof item.note === 'string' ? item.note : undefined,
                    )
                    const todo = isTodoChecklistItem(item)
                    const done = item.value_bool === true
                    const choiceLabel =
                      !todo &&
                      String(
                        item.option_label ?? item.state ?? item.option_semantics ?? '',
                      ).trim()

                    return (
                      <li
                        key={String(item.id ?? `${group.key}-${i}`)}
                        className="py-2.5"
                      >
                        <div className="flex items-start gap-2.5">
                          <ChecklistBullet />
                          <div className="min-w-0 flex-1">
                            <div className="flex items-start justify-between gap-3">
                              <div className="flex min-w-0 flex-wrap items-baseline gap-x-2 gap-y-0.5">
                                <p className="font-medium leading-snug">{label}</p>
                                {choiceLabel ? (
                                  <span className="sans text-xs text-[var(--muted)]">
                                    {choiceLabel}
                                  </span>
                                ) : null}
                              </div>
                              {todo ? <ChecklistTodoMark done={done} /> : null}
                            </div>
                            {note ? (
                              <p className="mt-1 border-l-2 border-[var(--line)] pl-3 text-sm text-[var(--muted)]">
                                {note}
                              </p>
                            ) : null}
                          </div>
                        </div>
                      </li>
                    )
                  })}
                </ul>
              </div>
            ))}
          </div>
        </section>
      )}

      {tasks.length > 0 && (
        <section className="mt-10">
          <h2 className="sans text-sm font-semibold uppercase tracking-wide text-[var(--accent)]">
            {t('tasks', 'Tasques')}
          </h2>
          <ul className="mt-3 space-y-3">
            {tasks.map((task, i) => {
              const title = String(
                task.title ?? t('task_fallback', 'Tasca {{n}}', { n: i + 1 }),
              )
              const statusKey = normalizeTaskStatus(task.status)
              const statusFallback =
                statusKey === 'pending'
                  ? 'Pendent'
                  : statusKey === 'in_progress'
                    ? 'En curs'
                    : statusKey === 'done'
                      ? 'Fet'
                      : statusKey === 'blocked'
                        ? 'Bloquejat'
                        : ''
              const statusLabel = statusKey
                ? t(`task_status_${statusKey}`, statusFallback)
                : null
              const notes = sanitizeClientHtml(
                typeof task.notes_html === 'string' ? task.notes_html : '',
              )
              return (
                <li
                  key={String(task.id ?? i)}
                  className="rounded-xl border border-[var(--line)] bg-white/70 px-4 py-3"
                >
                  <div className="flex items-start justify-between gap-3">
                    <p className="font-medium">{title}</p>
                    {statusKey && statusLabel ? (
                      <TaskStatusBadge status={statusKey} label={statusLabel} />
                    ) : null}
                  </div>
                  {notes ? (
                    <div
                      className="mt-2 prose-sm text-sm text-[var(--muted)]"
                      dangerouslySetInnerHTML={{ __html: notes }}
                    />
                  ) : null}
                </li>
              )
            })}
          </ul>
        </section>
      )}

      {materials.length > 0 && (
        <section className="mt-10">
          <h2 className="sans text-sm font-semibold uppercase tracking-wide text-[var(--accent)]">
            {t('materials', 'Materials')}
          </h2>
          <ul className="mt-3 border-y border-[var(--line)] divide-y divide-[var(--line)]">
            {materials.map((material, i) => {
              const name = String(
                material.name ?? t('material_fallback', 'Material {{n}}', { n: i + 1 }),
              )
              const qty = material.quantity
              const unit =
                typeof material.unit === 'string' ? material.unit.trim() : ''
              const qtyLabel =
                qty == null ? unit : unit ? `${qty} ${unit}` : String(qty)
              return (
                <li
                  key={String(material.id ?? i)}
                  className="flex items-baseline justify-between gap-3 py-2.5"
                >
                  <p className="font-medium">{name}</p>
                  {qtyLabel ? (
                    <span className="sans shrink-0 text-sm text-[var(--muted)]">
                      {qtyLabel}
                    </span>
                  ) : null}
                </li>
              )
            })}
          </ul>
        </section>
      )}

      {media.length > 0 && (
        <section className="mt-10">
          <h2 className="sans text-sm font-semibold uppercase tracking-wide text-[var(--accent)]">
            {t('attachments', 'Adjunts')}
          </h2>
          <ul className="mt-3 space-y-3 sans text-sm">
            {media.map((m, i) => {
              const key = String(m.object_key ?? m.id ?? i)
              const ctype = String(m.content_type ?? 'application/octet-stream')
              const name = mediaDisplayName(m, i)
              const qs =
                (actorType === 'grant' || actorType === 'staff') && reportVersionId
                  ? `?v=${encodeURIComponent(reportVersionId)}`
                  : ''
              const canInline = isInlineBrowserImage(ctype)
              const viewHref = mediaObjectHref(key, qs, false)
              const downloadHref = mediaObjectHref(key, qs, true)
              return (
                <li
                  key={key}
                  className="rounded-xl border border-[var(--line)] bg-white/70 px-4 py-3"
                >
                  {canInline ? (
                    <a
                      href={viewHref}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="mb-2 block"
                    >
                      <img
                        src={viewHref}
                        alt={name}
                        className="max-h-48 w-full rounded-lg object-contain bg-[var(--paper,#f7f4ef)]"
                      />
                    </a>
                  ) : null}
                  <p className="font-medium">{name}</p>
                  <p className="mt-0.5 text-xs text-[var(--muted)]">{ctype}</p>
                  <div className="mt-2 flex flex-wrap gap-x-4 gap-y-1">
                    {canInline ? (
                      <a
                        className="text-[var(--accent)] underline-offset-2 hover:underline"
                        href={viewHref}
                        target="_blank"
                        rel="noopener noreferrer"
                      >
                        {t('open_image', 'Obrir en nova finestra')}
                      </a>
                    ) : null}
                    <a
                      className="text-[var(--accent)] underline-offset-2 hover:underline"
                      href={downloadHref}
                      target="_blank"
                      rel="noopener noreferrer"
                    >
                      {t('download_file', 'Descarregar')}
                    </a>
                  </div>
                </li>
              )
            })}
          </ul>
        </section>
      )}

      <footer className="no-print mt-14 border-t border-[var(--line)] pt-6 sans text-xs text-[var(--muted)]">
        <p>
          {t(
            'confidential',
            'Document confidencial. No indexable. No compartiu aquest enllaç públicament.',
          )}
        </p>
        {privacyUrl && (
          <p className="mt-2">
            <a className="underline underline-offset-2" href={privacyUrl}>
              {t('privacy', 'Informació sobre el tractament de dades (Art. 13)')}
            </a>
          </p>
        )}
        <PrintButton label={t('print', 'Imprimir')} />
      </footer>

      <PortalFooter
        profile={tenantProfile ?? { display_name: tenantName || null }}
        tenantId={tenantId}
        locale={locale}
        showAccessLink={
          actorType === 'grant' ||
          (actorType === 'staff' && Boolean(accountContactId))
        }
      />
      <CookieNotice tenantId={tenantId} locale={locale} />
    </main>
  )
}
