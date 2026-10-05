export type AgendaView = 'list' | 'day' | 'week' | 'month'

const AGENDA_VIEWS = new Set<AgendaView>(['list', 'day', 'week', 'month'])
export type AgendaScope = 'mine' | 'all'

export type AgendaUrlState = {
  view: AgendaView
  scope: AgendaScope
  types: string[]
  statuses: string[]
  memberIds: string[]
  anchor: string | null
  tray: boolean
}

const VIEW_KEY = 'field_agenda_view'
const DEFAULT_TYPES = ['work_order', 'maintenance'] as const

export function parseAgendaView(raw: string | null | undefined, fallback: AgendaView): AgendaView {
  if (raw && AGENDA_VIEWS.has(raw as AgendaView)) return raw as AgendaView
  return fallback
}

export function parseAgendaScope(raw: string | null | undefined, fallback: AgendaScope): AgendaScope {
  if (raw === 'mine' || raw === 'all') return raw
  return fallback
}

function parseCsv(raw: string | null | undefined): string[] {
  if (!raw) return []
  return raw
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean)
}

export function readStoredAgendaView(): AgendaView | null {
  if (typeof localStorage === 'undefined') return null
  try {
    const raw = localStorage.getItem(VIEW_KEY)
    if (!raw || !AGENDA_VIEWS.has(raw as AgendaView)) return null
    return raw as AgendaView
  } catch {
    return null
  }
}

export function storeAgendaView(view: AgendaView) {
  if (typeof localStorage === 'undefined') return
  try {
    localStorage.setItem(VIEW_KEY, view)
  } catch {
    /* ignore quota */
  }
}

export function defaultAgendaViewForWidth(width: number): AgendaView {
  return width >= 1024 ? 'week' : 'list'
}

export function parseAgendaUrlState(
  searchParams: URLSearchParams,
  opts: { defaultView: AgendaView; defaultScope: AgendaScope },
): AgendaUrlState {
  const types = parseCsv(searchParams.get('types'))
  return {
    view: parseAgendaView(searchParams.get('view'), opts.defaultView),
    scope: parseAgendaScope(searchParams.get('scope'), opts.defaultScope),
    types: types.length > 0 ? types : [...DEFAULT_TYPES],
    statuses: parseCsv(searchParams.get('status')),
    memberIds: parseCsv(searchParams.get('tech')),
    anchor: searchParams.get('anchor'),
    tray: searchParams.get('tray') === '1',
  }
}

export function serializeAgendaUrlState(
  state: AgendaUrlState,
  opts: { defaultView: AgendaView; defaultScope: AgendaScope },
): URLSearchParams {
  const params = new URLSearchParams()
  if (state.view !== opts.defaultView) params.set('view', state.view)
  if (state.scope !== opts.defaultScope) params.set('scope', state.scope)
  const typesSorted = [...state.types].sort().join(',')
  const defaultTypes = [...DEFAULT_TYPES].sort().join(',')
  if (typesSorted !== defaultTypes) params.set('types', state.types.join(','))
  if (state.statuses.length > 0) params.set('status', state.statuses.join(','))
  if (state.memberIds.length > 0) params.set('tech', state.memberIds.join(','))
  if (state.anchor) params.set('anchor', state.anchor)
  if (state.tray) params.set('tray', '1')
  return params
}

export function hasActiveAgendaFilters(state: AgendaUrlState): boolean {
  const typesSorted = [...state.types].sort().join(',')
  const defaultTypes = [...DEFAULT_TYPES].sort().join(',')
  return (
    typesSorted !== defaultTypes ||
    state.statuses.length > 0 ||
    state.memberIds.length > 0
  )
}

export function parseAnchorDate(raw: string | null | undefined, fallback = new Date()): Date {
  if (!raw) return fallback
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(raw)
  if (!m) return fallback
  return new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]))
}

export function formatAnchorDate(date: Date): string {
  const y = date.getFullYear()
  const m = String(date.getMonth() + 1).padStart(2, '0')
  const d = String(date.getDate()).padStart(2, '0')
  return `${y}-${m}-${d}`
}
