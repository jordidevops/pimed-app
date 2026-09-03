export const attendanceKeys = {
  all: ['attendance'] as const,
  myEmployee: (tenantId: string) => ['attendance', 'my-employee', tenantId] as const,
  todayPunches: (employeeId: string) => ['attendance', 'today-punches', employeeId] as const,
  todayEntries: (employeeId: string) => ['attendance', 'today-entries', employeeId] as const,
  myPunches: (employeeId: string, from: string, to: string) =>
    ['attendance', 'my-punches', employeeId, from, to] as const,
  myEntries: (employeeId: string, from: string, to: string) =>
    ['attendance', 'my-entries', employeeId, from, to] as const,
  // Shifts & Planner
  workShifts: (siteId?: string | null) => ['attendance', 'work-shifts', siteId ?? 'all'] as const,
  shiftSlots: (siteId: string, from: string, to: string) =>
    ['attendance', 'shift-slots', siteId, from, to] as const,
  myShiftSlots: (employeeId: string, from: string, to: string) =>
    ['attendance', 'my-shift-slots', employeeId, from, to] as const,
  siteEmployees: (siteId: string) => ['attendance', 'site-employees', siteId] as const,
  coverage: (siteId: string, from: string, to: string) =>
    ['attendance', 'coverage', siteId, from, to] as const,
  // Absences
  myAbsences: (employeeId: string, from: string, to: string) =>
    ['attendance', 'my-absences', employeeId, from, to] as const,
  siteAbsences: (from: string, to: string) =>
    ['attendance', 'site-absences', from, to] as const,
  // Holidays
  siteHolidays: (siteId: string, from: string, to: string) =>
    ['attendance', 'site-holidays', siteId, from, to] as const,
  holidayCoverage: (siteId?: string | null) => ['attendance', 'holiday-coverage', siteId ?? 'none'] as const,
  calendarHolidays: (calendarId: string, from: string, to: string) =>
    ['attendance', 'calendar-holidays', calendarId, from, to] as const,
  // Admin time entries
  allDailySummaries: (siteId: string, from: string, to: string, employeeId?: string) =>
    ['attendance', 'all-summaries', siteId, from, to, employeeId ?? 'all'] as const,
  // Labor Calendar Setup
  holidayCalendars: (tenantId: string) => ['attendance', 'holiday-calendars', tenantId] as const,
  siteHolidayCalendarAssignments: (siteId: string) => ['attendance', 'site-hca', siteId] as const,
  tenantHolidayCalendarAssignments: (tenantId: string) => ['attendance', 'tenant-hca', tenantId] as const,
  siteHolidayExclusions: (siteId: string) => ['attendance', 'site-holiday-excl', siteId] as const,
  employeeDayOverrides: (employeeId: string) => ['attendance', 'emp-day-overrides', employeeId] as const,
  myWorkDay: (employeeId: string, date: string) =>
    ['attendance', 'my-work-day', employeeId, date] as const,
  myWorkDaysUpcoming: (employeeId: string, fromDate: string) =>
    ['attendance', 'my-work-days-upcoming', employeeId, fromDate] as const,
  geoEnabled: (employeeId: string) => ['attendance', 'geo-enabled', employeeId] as const,
}
