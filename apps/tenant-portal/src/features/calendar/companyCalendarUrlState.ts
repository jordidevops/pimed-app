export type CompanyCalendarView = 'list' | 'day' | 'week' | 'month'

const VIEWS = new Set<CompanyCalendarView>(['list', 'day', 'week', 'month'])
const SPANS = new Set([14, 28, 42])

export type CompanyCalendarUrlState = {
  view: CompanyCalendarView
  /** YYYY-MM-DD or null (= today when resolved) */
  date: string | null
  /** Empty = all types */
  types: string[]
  /** `all` or site UUID */
  site: string
  span: 14 | 28 | 42
  create: boolean
  /** Free-text search query (title/description); empty = inactive */
  q: string
  /** When true, only events that belong to the current user («Els meus»). */
  mine: boolean
}

const VIEW_KEY = 'company_calendar_view'

export function parseCompanyCalendarView(
  raw: string | null | undefined,
  fallback: CompanyCalendarView,
): CompanyCalendarView {
  if (raw && VIEWS.has(raw as CompanyCalendarView)) return raw as CompanyCalendarView
  return fallback
}

function parseCsv(raw: string | null | undefined): string[] {
  if (!raw) return []
  return raw
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean)
}

export function parseSpan(raw: string | null | undefined, fallback: 14 | 28 | 42 = 14): 14 | 28 | 42 {
  const n = Number(raw)
  if (SPANS.has(n)) return n as 14 | 28 | 42
  return fallback
}

export function parseSiteParam(
  raw: string | null | undefined,
  defaultSite: string,
): string {
  if (raw === 'all') return 'all'
  if (raw && /^[0-9a-f-]{36}$/i.test(raw)) return raw
  return defaultSite
}

export function readStoredCompanyCalendarView(): CompanyCalendarView | null {
  if (typeof localStorage === 'undefined') return null
  try {
    const raw = localStorage.getItem(VIEW_KEY)
    if (!raw || !VIEWS.has(raw as CompanyCalendarView)) return null
    return raw as CompanyCalendarView
  } catch {
    return null
  }
}

export function storeCompanyCalendarView(view: CompanyCalendarView) {
  if (typeof localStorage === 'undefined') return
  try {
    localStorage.setItem(VIEW_KEY, view)
  } catch {
    /* ignore quota */
  }
}

/** Desktop default from settings; mobile always prefers list. */
export function resolveDefaultCompanyCalendarView(opts: {
  width: number
  settingsView?: string | null
  stored?: CompanyCalendarView | null
}): CompanyCalendarView {
  if (opts.width < 1024) return 'list'
  if (opts.stored && opts.stored !== 'list') return opts.stored
  const fromSettings = opts.settingsView
  if (fromSettings === 'day' || fromSettings === 'week' || fromSettings === 'month') {
    return fromSettings
  }
  return 'week'
}

export function parseCompanyCalendarUrlState(
  searchParams: URLSearchParams,
  opts: { defaultView: CompanyCalendarView; defaultSite: string },
): CompanyCalendarUrlState {
  return {
    view: parseCompanyCalendarView(searchParams.get('view'), opts.defaultView),
    date: searchParams.get('date'),
    types: parseCsv(searchParams.get('types')),
    site: parseSiteParam(searchParams.get('site'), opts.defaultSite),
    span: parseSpan(searchParams.get('span'), 14),
    create: searchParams.get('create') === '1',
    q: (searchParams.get('q') ?? '').trim(),
    mine: searchParams.get('mine') === '1',
  }
}

export function serializeCompanyCalendarUrlState(
  state: CompanyCalendarUrlState,
  opts: { defaultView: CompanyCalendarView; defaultSite: string },
): URLSearchParams {
  const params = new URLSearchParams()
  if (state.view !== opts.defaultView) params.set('view', state.view)
  if (state.date) params.set('date', state.date)
  if (state.types.length > 0) params.set('types', state.types.join(','))
  if (state.site !== opts.defaultSite) params.set('site', state.site)
  if (state.view === 'list' && state.span !== 14) params.set('span', String(state.span))
  if (state.create) params.set('create', '1')
  const q = state.q.trim()
  if (q) params.set('q', q)
  if (state.mine) params.set('mine', '1')
  return params
}

export function hasActiveCompanyCalendarFilters(state: CompanyCalendarUrlState): boolean {
  return (
    state.types.length > 0 ||
    state.site !== 'all' ||
    state.q.trim().length > 0 ||
    state.mine
  )
}

export function parseCalendarDate(raw: string | null | undefined, fallback = new Date()): Date {
  if (!raw) return fallback
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(raw)
  if (!m) return fallback
  return new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]))
}

export function formatCalendarDate(date: Date): string {
  const y = date.getFullYear()
  const m = String(date.getMonth() + 1).padStart(2, '0')
  const d = String(date.getDate()).padStart(2, '0')
  return `${y}-${m}-${d}`
}

export function nextListSpan(current: 14 | 28 | 42): 14 | 28 | 42 | null {
  if (current === 14) return 28
  if (current === 28) return 42
  return null
}
