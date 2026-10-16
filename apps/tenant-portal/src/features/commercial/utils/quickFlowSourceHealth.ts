export type QuickFlowSourceRefs = {
  calculator_definition_id: string | null
  pricing_template_id: string | null
}

export type QuickFlowCalcLike = {
  id: string
  status: string
  published_version_id: string | null
}

export type QuickFlowHabitLike = {
  id: string
  is_active?: boolean
}

export type QuickFlowSourceWarning =
  | 'calc_missing'
  | 'calc_inactive'
  | 'habit_missing'
  | 'habit_inactive'

export function quickFlowSourceWarning(
  flow: QuickFlowSourceRefs,
  calcById: Map<string, QuickFlowCalcLike>,
  habitById: Map<string, QuickFlowHabitLike>,
): QuickFlowSourceWarning | null {
  if (flow.calculator_definition_id) {
    const calc = calcById.get(flow.calculator_definition_id)
    if (!calc) return 'calc_missing'
    if (calc.status !== 'active' || !calc.published_version_id) return 'calc_inactive'
  }
  if (flow.pricing_template_id) {
    const habit = habitById.get(flow.pricing_template_id)
    if (!habit) return 'habit_missing'
    if (habit.is_active === false) return 'habit_inactive'
  }
  return null
}

export function isQuickFlowSourceLaunchable(
  flow: QuickFlowSourceRefs,
  calcById: Map<string, QuickFlowCalcLike>,
  habitById: Map<string, QuickFlowHabitLike>,
): boolean {
  return quickFlowSourceWarning(flow, calcById, habitById) == null
}
