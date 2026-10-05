import { describe, expect, it } from 'vitest'
import {
  formatCalendarDate,
  hasActiveCompanyCalendarFilters,
  nextListSpan,
  parseCalendarDate,
  parseCompanyCalendarUrlState,
  parseSiteParam,
  resolveDefaultCompanyCalendarView,
  serializeCompanyCalendarUrlState,
} from './companyCalendarUrlState'

describe('companyCalendarUrlState', () => {
  it('round-trips filters in the URL', () => {
    const defaults = { defaultView: 'week' as const, defaultSite: 'all' }
    const state = parseCompanyCalendarUrlState(
      new URLSearchParams(
        'view=month&date=2026-10-08&types=manual,task&site=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee&span=28&create=1',
      ),
      defaults,
    )
    expect(state).toEqual({
      view: 'month',
      date: '2026-10-08',
      types: ['manual', 'task'],
      site: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
      span: 28,
      create: true,
      q: '',
      mine: false,
    })
    expect(hasActiveCompanyCalendarFilters(state)).toBe(true)
    expect(serializeCompanyCalendarUrlState(state, defaults).toString()).toBe(
      'view=month&date=2026-10-08&types=manual%2Ctask&site=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee&create=1',
    )
  })

  it('round-trips search query q', () => {
    const defaults = { defaultView: 'week' as const, defaultSite: 'all' }
    const state = parseCompanyCalendarUrlState(
      new URLSearchParams('q=reuni%C3%B3'),
      defaults,
    )
    expect(state.q).toBe('reunió')
    expect(serializeCompanyCalendarUrlState(state, defaults).get('q')).toBe('reunió')
    expect(hasActiveCompanyCalendarFilters(state)).toBe(true)
  })

  it('round-trips mine=1', () => {
    const defaults = { defaultView: 'week' as const, defaultSite: 'all' }
    const state = parseCompanyCalendarUrlState(new URLSearchParams('mine=1'), defaults)
    expect(state.mine).toBe(true)
    expect(serializeCompanyCalendarUrlState(state, defaults).toString()).toBe('mine=1')
    expect(hasActiveCompanyCalendarFilters(state)).toBe(true)
  })

  it('omits defaults from serialized params', () => {
    const defaults = { defaultView: 'list' as const, defaultSite: 'site-1' }
    const state = parseCompanyCalendarUrlState(new URLSearchParams(), defaults)
    expect(state.view).toBe('list')
    expect(state.site).toBe('site-1')
    expect(state.span).toBe(14)
    expect(serializeCompanyCalendarUrlState(state, defaults).toString()).toBe('')
  })

  it('serializes span only for list view when not 14', () => {
    const defaults = { defaultView: 'list' as const, defaultSite: 'all' }
    const list = parseCompanyCalendarUrlState(new URLSearchParams('span=28'), defaults)
    expect(serializeCompanyCalendarUrlState(list, defaults).toString()).toBe('span=28')
    const week = { ...list, view: 'week' as const }
    expect(serializeCompanyCalendarUrlState(week, defaults).toString()).toBe('view=week')
  })

  it('parses site=all and rejects invalid site', () => {
    expect(parseSiteParam('all', 'fallback')).toBe('all')
    expect(parseSiteParam('not-a-uuid', 'fallback')).toBe('fallback')
  })

  it('parses and formats calendar dates', () => {
    const d = parseCalendarDate('2026-03-15')
    expect(formatCalendarDate(d)).toBe('2026-03-15')
    expect(parseCalendarDate('bad').getDate()).toBe(new Date().getDate())
  })

  it('resolves default view: mobile list, desktop settings/stored', () => {
    expect(
      resolveDefaultCompanyCalendarView({ width: 400, settingsView: 'month' }),
    ).toBe('list')
    expect(
      resolveDefaultCompanyCalendarView({ width: 1280, settingsView: 'month' }),
    ).toBe('month')
    expect(
      resolveDefaultCompanyCalendarView({
        width: 1280,
        settingsView: 'list',
        stored: 'day',
      }),
    ).toBe('day')
    expect(resolveDefaultCompanyCalendarView({ width: 1280 })).toBe('week')
  })

  it('advances list span up to 42', () => {
    expect(nextListSpan(14)).toBe(28)
    expect(nextListSpan(28)).toBe(42)
    expect(nextListSpan(42)).toBeNull()
  })
})
