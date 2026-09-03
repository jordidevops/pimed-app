import DOMPurify from 'dompurify'
import { useTranslation } from 'react-i18next'

export type BulletinPreviewMediaItem = {
  id: string
  name: string
  contentType: string
  /** Optional signed URL for HTML-displayable images (tenant-side preview only). */
  previewUrl?: string | null
  /** Signed URL to open/download the file (always set when available). */
  fileUrl?: string | null
}

type Props = {
  projection: Record<string, unknown>
  locale: string
  tenantNameFallback?: string
  contentDigest?: string
  media?: BulletinPreviewMediaItem[]
  /** Banner when previewing an unpublished draft. */
  draftBanner?: boolean
}

const HTML_ALLOWED = {
  ALLOWED_TAGS: [
    'p',
    'br',
    'strong',
    'em',
    'ul',
    'ol',
    'li',
    'h1',
    'h2',
    'h3',
    'h4',
    'span',
    'a',
  ],
  ALLOWED_ATTR: ['href', 'title', 'rel', 'target', 'class'],
}

function sanitizeClientHtml(html: string | null | undefined): string {
  if (!html) return ''
  return DOMPurify.sanitize(html, HTML_ALLOWED)
}

function plainText(html: string | null | undefined): string {
  if (!html) return ''
  return DOMPurify.sanitize(html, { ALLOWED_TAGS: [], ALLOWED_ATTR: [] }).trim()
}

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
      className="inline-flex h-4 w-4 shrink-0 items-center justify-center rounded-sm bg-[var(--bp-accent)] text-white"
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
    <span className="mt-2 h-1.5 w-1.5 shrink-0 rounded-full bg-[var(--bp-ink)]" aria-hidden />
  )
}

type TaskStatusKey = 'pending' | 'in_progress' | 'done' | 'blocked'

function normalizeTaskStatus(raw: unknown): TaskStatusKey | null {
  const s = String(raw ?? '').trim().toLowerCase()
  if (s === 'pending' || s === 'todo') return 'pending'
  if (s === 'in_progress' || s === 'in-progress' || s === 'doing') return 'in_progress'
  if (s === 'done' || s === 'completed' || s === 'complete') return 'done'
  if (s === 'blocked') return 'blocked'
  return null
}

function TaskStatusBadge({ status, label }: { status: TaskStatusKey; label: string }) {
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
      ? 'bg-[#e8f2ee] text-[var(--bp-accent)]'
      : status === 'blocked'
        ? 'bg-[#f4ebe3] text-[#8a4b2e]'
        : 'bg-[var(--bp-paper)] text-[var(--bp-muted)]'

  return (
    <span className={`bp-sans inline-flex shrink-0 items-center gap-1 rounded-full px-2 py-0.5 text-xs ${tone}`}>
      {icon}
      {label}
    </span>
  )
}

/**
 * Tenant-side preview that mirrors customer-portal BulletinReader layout
 * (resum + checklist + media). Work notes are never included.
 */
export function BulletinClientPreview({
  projection,
  locale,
  tenantNameFallback,
  contentDigest,
  media = [],
  draftBanner = false,
}: Props) {
  const { t } = useTranslation('field-service')

  const summaryHtml = sanitizeClientHtml(
    typeof projection.client_summary_html === 'string' ? projection.client_summary_html : '',
  )
  const tenantName =
    projection.tenant && typeof projection.tenant === 'object'
      ? String((projection.tenant as Record<string, unknown>).name ?? '')
      : ''
  const title = tenantName || tenantNameFallback || t('bulletin.preview_fallback_title', 'Intervenció')
  const items = checklistItems(projection)
  const tasks = taskItems(projection)
  const materials = materialItems(projection)

  return (
    <div className="bulletin-client-preview mx-auto max-w-2xl px-1 py-2 sm:px-2">
      <style>{`
        .bulletin-client-preview {
          --bp-ink: #14213d;
          --bp-paper: #f7f4ef;
          --bp-accent: #1b6b5a;
          --bp-muted: #5c667a;
          --bp-line: #d9d2c5;
          color: var(--bp-ink);
          background:
            radial-gradient(900px 400px at 10% -20%, #e8f2ee 0%, transparent 55%),
            radial-gradient(700px 320px at 100% 0%, #efe6d8 0%, transparent 50%),
            var(--bp-paper);
          border-radius: 1rem;
          font-family: "Source Serif 4", "Iowan Old Style", "Palatino Linotype", Palatino, Georgia, serif;
          line-height: 1.55;
        }
        .bulletin-client-preview .bp-sans {
          font-family: "IBM Plex Sans", "Segoe UI", system-ui, sans-serif;
        }
        .bulletin-client-preview .bp-prose a {
          color: var(--bp-accent);
          text-decoration: underline;
          text-underline-offset: 2px;
        }
        .bulletin-client-preview .bp-prose p { margin: 0.5rem 0; }
        .bulletin-client-preview .bp-prose ul,
        .bulletin-client-preview .bp-prose ol { margin: 0.5rem 0; padding-left: 1.25rem; }
      `}</style>

      <div className="px-4 py-6 sm:px-6 sm:py-8">
        {draftBanner && (
          <div className="bp-sans mb-6 rounded-lg border border-[var(--bp-line)] bg-white/60 px-3 py-2 text-sm text-[var(--bp-muted)]">
            {t(
              'bulletin.preview_draft_banner',
              'Vista prèvia de l’esborrany (com el veurà el client). Les notes de feina no s’inclouen.',
            )}
          </div>
        )}

        <header className="border-b border-[var(--bp-line)] pb-6">
          <p className="bp-sans text-xs uppercase tracking-[0.18em] text-[var(--bp-muted)]">
            {t('bulletin.preview_kicker', 'Butlletí d’intervenció')}
          </p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight sm:text-4xl">{title}</h1>
          <p className="bp-sans mt-2 text-xs text-[var(--bp-muted)]">
            {contentDigest
              ? t('bulletin.preview_ref', 'Ref. {{digest}} · {{locale}}', {
                  digest: contentDigest.slice(0, 12),
                  locale,
                })
              : t('bulletin.preview_locale', 'Locale {{locale}}', { locale })}
          </p>
        </header>

        {summaryHtml ? (
          <section className="mt-8">
            <h2 className="bp-sans text-sm font-semibold uppercase tracking-wide text-[var(--bp-accent)]">
              {t('bulletin.preview_summary', 'Resum')}
            </h2>
            <div
              className="bp-prose mt-3 text-sm leading-relaxed"
              dangerouslySetInnerHTML={{ __html: summaryHtml }}
            />
          </section>
        ) : (
          <section className="mt-8">
            <h2 className="bp-sans text-sm font-semibold uppercase tracking-wide text-[var(--bp-accent)]">
              {t('bulletin.preview_summary', 'Resum')}
            </h2>
            <p className="bp-sans mt-3 text-sm text-[var(--bp-muted)]">
              {t('bulletin.preview_no_summary', 'Sense resum per al client.')}
            </p>
          </section>
        )}

        {items.length > 0 && (
          <section className="mt-10">
            <h2 className="bp-sans text-sm font-semibold uppercase tracking-wide text-[var(--bp-accent)]">
              {t('bulletin.preview_checklist', 'Checklist')}
            </h2>
            <div className="mt-3 space-y-6">
              {groupChecklistByRun(items).map((group, gi) => (
                <div key={group.key}>
                  <h3 className="text-base font-semibold tracking-tight">
                    {group.title ||
                      t('bulletin.checklist_untitled', 'Checklist {{n}}', { n: gi + 1 })}
                  </h3>
                  <ul className="mt-3 border-y border-[var(--bp-line)] divide-y divide-[var(--bp-line)]">
                    {group.items.map((item, i) => {
                      const label = String(
                        item.label ?? item.title ?? item.name ?? `Ítem ${i + 1}`,
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
                                    <span className="bp-sans text-xs text-[var(--bp-muted)]">
                                      {choiceLabel}
                                    </span>
                                  ) : null}
                                </div>
                                {todo ? <ChecklistTodoMark done={done} /> : null}
                              </div>
                              {note ? (
                                <p className="mt-1 border-l-2 border-[var(--bp-line)] pl-3 text-sm text-[var(--bp-muted)]">
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
            <h2 className="bp-sans text-sm font-semibold uppercase tracking-wide text-[var(--bp-accent)]">
              {t('bulletin.preview_tasks', 'Tasques')}
            </h2>
            <ul className="mt-3 space-y-3">
              {tasks.map((task, i) => {
                const title = String(task.title ?? `Tasca ${i + 1}`)
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
                  ? t(`bulletin.task_status_${statusKey}`, statusFallback)
                  : null
                const notes = sanitizeClientHtml(
                  typeof task.notes_html === 'string' ? task.notes_html : '',
                )
                return (
                  <li
                    key={String(task.id ?? i)}
                    className="rounded-xl border border-[var(--bp-line)] bg-white/70 px-4 py-3"
                  >
                    <div className="flex items-start justify-between gap-3">
                      <p className="font-medium">{title}</p>
                      {statusKey && statusLabel ? (
                        <TaskStatusBadge status={statusKey} label={statusLabel} />
                      ) : null}
                    </div>
                    {notes ? (
                      <div
                        className="bp-prose mt-2 text-sm text-[var(--bp-muted)]"
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
            <h2 className="bp-sans text-sm font-semibold uppercase tracking-wide text-[var(--bp-accent)]">
              {t('bulletin.preview_materials', 'Materials')}
            </h2>
            <ul className="mt-3 border-y border-[var(--bp-line)] divide-y divide-[var(--bp-line)]">
              {materials.map((material, i) => {
                const name = String(material.name ?? `Material ${i + 1}`)
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
                      <span className="bp-sans shrink-0 text-sm text-[var(--bp-muted)]">
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
            <h2 className="bp-sans text-sm font-semibold uppercase tracking-wide text-[var(--bp-accent)]">
              {t('bulletin.preview_attachments', 'Adjunts')}
            </h2>
            <ul className="bp-sans mt-3 space-y-3 text-sm">
              {media.map((m, i) => {
                const canInline = isInlineBrowserImage(m.contentType) && Boolean(m.previewUrl)
                const openUrl = m.previewUrl || m.fileUrl
                const downloadUrl = m.fileUrl || m.previewUrl
                const label = m.name || t('bulletin.preview_file_n', 'Fitxer {{n}}', { n: i + 1 })
                return (
                  <li
                    key={m.id}
                    className="rounded-xl border border-[var(--bp-line)] bg-white/70 px-4 py-3"
                  >
                    {canInline && m.previewUrl ? (
                      <a
                        href={openUrl ?? undefined}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="mb-2 block"
                      >
                        <img
                          src={m.previewUrl}
                          alt={m.name}
                          className="max-h-48 w-full rounded-lg object-contain bg-[var(--bp-paper)]"
                        />
                      </a>
                    ) : null}
                    <p className="font-medium">{label}</p>
                    <p className="text-xs text-[var(--bp-muted)]">{m.contentType}</p>
                    {downloadUrl ? (
                      <div className="mt-2 flex flex-wrap gap-x-4 gap-y-1">
                        {canInline && openUrl ? (
                          <a
                            className="font-medium text-[var(--bp-accent)] underline-offset-2 hover:underline"
                            href={openUrl}
                            target="_blank"
                            rel="noopener noreferrer"
                          >
                            {t('bulletin.open_image', 'Obrir en nova finestra')}
                          </a>
                        ) : null}
                        <a
                          className="font-medium text-[var(--bp-accent)] underline-offset-2 hover:underline"
                          href={downloadUrl}
                          target="_blank"
                          rel="noopener noreferrer"
                        >
                          {t('bulletin.download_file', 'Descarregar')}
                        </a>
                      </div>
                    ) : (
                      <p className="mt-2 text-xs text-[var(--bp-muted)]">
                        {t(
                          'bulletin.preview_file_no_url',
                          'No s’ha pogut obtenir l’enllaç del fitxer.',
                        )}
                      </p>
                    )}
                  </li>
                )
              })}
            </ul>
          </section>
        )}

        <footer className="bp-sans mt-10 border-t border-[var(--bp-line)] pt-4 text-xs text-[var(--bp-muted)]">
          <p>
            {t(
              'bulletin.preview_footer',
              'Document confidencial. Així el veurà el client al portal (sense notes de feina).',
            )}
          </p>
        </footer>
      </div>
    </div>
  )
}
