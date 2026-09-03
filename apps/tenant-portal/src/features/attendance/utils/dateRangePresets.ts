import { useMemo } from 'react'
import { madridWorkDate } from '../api/todayDashboardService'

export type DateRangePresetId = 'today' | 'this_week' | 'this_month' | 'prev_month' | 'this_year'

export interface DateRangePreset {
  id: DateRangePresetId
  from: string
  to: string
}

function pad(n: number) {
  return String(n).padStart(2, '0')
}

function isoDate(y: number, m: number, d: number) {
  return `${y}-${pad(m)}-${pad(d)}`
}

function monthBounds(year: number, month: number) {
  const from = isoDate(year, month + 1, 1)
  const last = new Date(year, month + 1, 0).getDate()
  const to = isoDate(year, month + 1, last)
  return { from, to }
}

export function buildDateRangePresets(anchor = new Date(), weekStartsOn = 1): DateRangePreset[] {
  const today = madridWorkDate(anchor.toISOString())
  const y = anchor.getFullYear()
  const m = anchor.getMonth()

  const thisMonth = monthBounds(y, m)
  const prevMonthDate = new Date(y, m - 1, 1)
  const prevMonth = monthBounds(prevMonthDate.getFullYear(), prevMonthDate.getMonth())

  const weekStart = new Date(`${today}T12:00:00`)
  const jsDow = weekStart.getDay()
  const diff = (jsDow - weekStartsOn + 7) % 7
  weekStart.setDate(weekStart.getDate() - diff)
  const weekEnd = new Date(weekStart)
  weekEnd.setDate(weekEnd.getDate() + 6)

  const weekFrom = madridWorkDate(weekStart.toISOString())
  const weekTo = madridWorkDate(weekEnd.toISOString())

  return [
    { id: 'today', from: today, to: today },
    { id: 'this_week', from: weekFrom, to: weekTo },
    { id: 'this_month', from: thisMonth.from, to: thisMonth.to },
    { id: 'prev_month', from: prevMonth.from, to: prevMonth.to },
    { id: 'this_year', from: isoDate(y, 1, 1), to: isoDate(y, 12, 31) },
  ]
}

export function useDateRangePresets(weekStartsOn: number) {
  return useMemo(() => buildDateRangePresets(new Date(), weekStartsOn), [weekStartsOn])
}

export function recordsPageHref(from: string, to: string, employeeId?: string) {
  const params = new URLSearchParams({ from, to })
  if (employeeId) params.set('employeeId', employeeId)
  return `/attendance-mgmt/records?${params.toString()}`
}
