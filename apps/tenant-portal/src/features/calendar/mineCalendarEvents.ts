/**
 * Contracte «Els meus events» (V2.2) per entity_type registrat:
 *
 * | entity_type | Regla |
 * |-------------|--------|
 * | manual      | `owner_id === userId` |
 * | task        | `tasks.assignee_id === userId` (lookup per `entity_id`);
 * |             | també `metadata.assignee_id` / `metadata.assignee_user_id` si hi són |
 * | shift_slot  | `metadata.employee_id === myEmployeeId` |
 * | project     | No és personal: mai «meu» a V2.2 (és context d’empresa/camp) |
 * | altres      | `owner_id === userId` (fallback conservador) |
 *
 * El filtre «meu» es combina en AND amb tipus / site / cerca.
 */

export type MineableCalendarEvent = {
  id: string
  entity_type?: string | null
  entity_id?: string | null
  owner_id?: string | null
  metadata?: unknown
}

export type MineFilterContext = {
  userId: string | null | undefined
  /** `data.employees.id` for the signed-in user in the active tenant. */
  myEmployeeId: string | null | undefined
  /**
   * Map `tasks.id` → `assignee_id` for task events in the current result set.
   * Missing keys mean “not assigned to me” for mine purposes.
   */
  taskAssigneeById?: ReadonlyMap<string, string | null>
}

function metaString(metadata: unknown, key: string): string | null {
  if (!metadata || typeof metadata !== 'object' || Array.isArray(metadata)) return null
  const value = (metadata as Record<string, unknown>)[key]
  return typeof value === 'string' && value.length > 0 ? value : null
}

export function isMyCalendarEvent(
  event: MineableCalendarEvent,
  ctx: MineFilterContext,
): boolean {
  const userId = ctx.userId
  if (!userId) return false

  const type = event.entity_type ?? ''

  if (type === 'project') return false

  if (type === 'manual') {
    return event.owner_id != null && event.owner_id === userId
  }

  if (type === 'shift_slot') {
    const employeeId = metaString(event.metadata, 'employee_id')
    return Boolean(ctx.myEmployeeId && employeeId && employeeId === ctx.myEmployeeId)
  }

  if (type === 'task') {
    const metaAssignee =
      metaString(event.metadata, 'assignee_id') ??
      metaString(event.metadata, 'assignee_user_id')
    if (metaAssignee && metaAssignee === userId) return true
    if (event.entity_id && ctx.taskAssigneeById) {
      const assignee = ctx.taskAssigneeById.get(event.entity_id)
      if (assignee != null && assignee === userId) return true
    }
    return false
  }

  return event.owner_id != null && event.owner_id === userId
}

export function filterMyCalendarEvents<T extends MineableCalendarEvent>(
  events: T[],
  ctx: MineFilterContext,
): T[] {
  if (!ctx.userId) return []
  return events.filter((event) => isMyCalendarEvent(event, ctx))
}

export function collectTaskEntityIds(events: MineableCalendarEvent[]): string[] {
  const ids = new Set<string>()
  for (const event of events) {
    if (event.entity_type === 'task' && typeof event.entity_id === 'string' && event.entity_id) {
      ids.add(event.entity_id)
    }
  }
  return [...ids]
}
