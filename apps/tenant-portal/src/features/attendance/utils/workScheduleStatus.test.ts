import { describe, expect, it } from 'vitest'
import {
  computeWorkScheduleStatus,
  getSchedulePhase,
  type WorkScheduleDayInput,
} from './workScheduleStatus'

const workDay = (intervals: Array<{ start: string; end: string }>): WorkScheduleDayInput => ({
  dayType: 'working',
  laborDayType: 'work',
  intervals,
  holidayName: null,
  isAbsence: false,
})

describe('getSchedulePhase', () => {
  it('detecta abans del primer tram', () => {
    const phase = getSchedulePhase([{ start: '08:00', end: '14:00' }], new Date('2026-07-13T07:30:00'))
    expect(phase).toEqual({ phase: 'before' })
  })

  it('detecta horari partit amb descans', () => {
    const intervals = [
      { start: '08:00', end: '14:00' },
      { start: '16:00', end: '18:00' },
    ]
    expect(getSchedulePhase(intervals, new Date('2026-07-13T10:00:00'))).toEqual({ phase: 'slot', index: 0 })
    expect(getSchedulePhase(intervals, new Date('2026-07-13T15:00:00'))).toEqual({ phase: 'break', afterIndex: 0 })
    expect(getSchedulePhase(intervals, new Date('2026-07-13T17:00:00'))).toEqual({ phase: 'slot', index: 1 })
    expect(getSchedulePhase(intervals, new Date('2026-07-13T19:00:00'))).toEqual({ phase: 'after' })
  })
})

describe('computeWorkScheduleStatus', () => {
  it('informa de vacances', () => {
    const result = computeWorkScheduleStatus({
      schedule: {
        dayType: 'vacation',
        laborDayType: 'vacation',
        intervals: [],
        holidayName: null,
        isAbsence: false,
      },
      punches: [],
      presenceStatus: 'outside',
    })
    expect(result?.kind).toBe('info')
    expect(result?.titleKey).toBe('work_status.vacation_day')
  })

  it('alerta si falta entrada durant el matí', () => {
    const result = computeWorkScheduleStatus({
      schedule: workDay([{ start: '08:00', end: '14:00' }]),
      punches: [],
      presenceStatus: 'outside',
      now: new Date('2026-07-13T10:00:00'),
    })
    expect(result?.kind).toBe('error')
    expect(result?.titleKey).toBe('work_status.missing_entry')
  })

  it('confirma treball en horari', () => {
    const result = computeWorkScheduleStatus({
      schedule: workDay([{ start: '08:00', end: '14:00' }]),
      punches: [{ punch_type: 'in', occurred_at: '2026-07-13T08:05:00Z' }],
      presenceStatus: 'working',
      now: new Date('2026-07-13T10:00:00'),
    })
    expect(result?.kind).toBe('success')
    expect(result?.titleKey).toBe('work_status.working')
  })

  it('detecta falta de sortida de matí en horari partit', () => {
    const result = computeWorkScheduleStatus({
      schedule: workDay([
        { start: '08:00', end: '14:00' },
        { start: '16:00', end: '18:00' },
      ]),
      punches: [{ punch_type: 'in', occurred_at: '2026-07-13T08:00:00Z' }],
      presenceStatus: 'working',
      now: new Date('2026-07-13T15:00:00'),
    })
    expect(result?.kind).toBe('warning')
    expect(result?.titleKey).toBe('work_status.missing_morning_exit')
  })
})
