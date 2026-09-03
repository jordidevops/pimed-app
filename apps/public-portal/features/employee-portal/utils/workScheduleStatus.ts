export type WorkInterval = { start: string; end: string }

export type PunchPresenceStatus =
  | 'outside'
  | 'on_day'
  | 'working'
  | 'on_pause'
  | 'traveling'
  | 'unknown'

export type WorkScheduleStatusKind = 'success' | 'warning' | 'error' | 'info'

export interface WorkScheduleStatusMessage {
  kind: WorkScheduleStatusKind
  titleKey: string
  titleDefault: string
  descriptionKey: string
  descriptionDefault: string
  descriptionParams?: Record<string, string | number>
}

export interface WorkScheduleDayInput {
  dayType: string
  laborDayType: string | null
  intervals: WorkInterval[]
  holidayName: string | null
  isHoliday?: boolean
  isAbsence: boolean
}

export interface WorkSchedulePunchInput {
  punch_type: string | null
  occurred_at?: string | null
}

export interface ComputeWorkScheduleStatusParams {
  schedule: WorkScheduleDayInput | null
  punches: WorkSchedulePunchInput[]
  presenceStatus: PunchPresenceStatus
  now?: Date
  scheduleDetail?: string
  soonThresholdMinutes?: number
}

type SchedulePhase =
  | { phase: 'before' }
  | { phase: 'slot'; index: number }
  | { phase: 'break'; afterIndex: number }
  | { phase: 'after' }

export function isWorkLaborDayInput(day: WorkScheduleDayInput): boolean {
  return day.laborDayType === 'work' || day.dayType === 'working'
}

function parseTimeOnDate(timeStr: string, base: Date): Date {
  const [h, m] = timeStr.split(':').map(Number)
  const d = new Date(base)
  d.setHours(h, m, 0, 0)
  return d
}

function intervalEndOnDate(start: string, end: string, base: Date): Date {
  const startAt = parseTimeOnDate(start, base)
  let endAt = parseTimeOnDate(end, base)
  if (endAt.getTime() <= startAt.getTime()) {
    endAt = new Date(endAt.getTime() + 24 * 60 * 60 * 1000)
  }
  return endAt
}

export function getSchedulePhase(intervals: WorkInterval[], now: Date): SchedulePhase {
  if (intervals.length === 0) return { phase: 'after' }

  const t = now.getTime()
  const firstStart = parseTimeOnDate(intervals[0]!.start, now)
  if (t < firstStart.getTime()) return { phase: 'before' }

  for (let i = 0; i < intervals.length; i++) {
    const slot = intervals[i]!
    const startAt = parseTimeOnDate(slot.start, now)
    const endAt = intervalEndOnDate(slot.start, slot.end, now)

    if (t >= startAt.getTime() && t < endAt.getTime()) {
      return { phase: 'slot', index: i }
    }

    if (i < intervals.length - 1) {
      const nextStart = parseTimeOnDate(intervals[i + 1]!.start, now)
      if (t >= endAt.getTime() && t < nextStart.getTime()) {
        return { phase: 'break', afterIndex: i }
      }
    }
  }

  return { phase: 'after' }
}

function minutesUntil(target: Date, now: Date): number {
  return Math.max(0, Math.floor((target.getTime() - now.getTime()) / 60_000))
}

function isWorkingPresence(status: PunchPresenceStatus): boolean {
  return status === 'working' || status === 'traveling'
}

function isOutPresence(status: PunchPresenceStatus): boolean {
  return status === 'outside' || status === 'on_day'
}

function hasPunchedToday(punches: WorkSchedulePunchInput[], now: Date): boolean {
  const dayStart = new Date(now)
  dayStart.setHours(0, 0, 0, 0)
  const dayEnd = new Date(now)
  dayEnd.setHours(23, 59, 59, 999)

  return punches.some((p) => {
    if (!p.occurred_at) return true
    const at = new Date(p.occurred_at).getTime()
    return at >= dayStart.getTime() && at <= dayEnd.getTime()
  })
}

function dayEnded(punches: WorkSchedulePunchInput[]): boolean {
  return punches.some((p) => p.punch_type === 'day_end' || p.punch_type === 'out')
}

export function computeWorkScheduleStatus(
  params: ComputeWorkScheduleStatusParams,
): WorkScheduleStatusMessage | null {
  const {
    schedule,
    punches,
    presenceStatus,
    now = new Date(),
    soonThresholdMinutes = 15,
  } = params

  if (!schedule) return null

  if (schedule.laborDayType === 'vacation' || schedule.dayType === 'vacation') {
    return {
      kind: 'info',
      titleKey: 'work_status.vacation_day',
      titleDefault: 'Dia de vacances',
      descriptionKey: 'work_status.vacation_description',
      descriptionDefault: 'Avui és un dia de vacances programat.',
    }
  }

  if (
    schedule.isHoliday ||
    schedule.laborDayType === 'holiday' ||
    schedule.dayType === 'holiday' ||
    schedule.dayType === 'half_holiday' ||
    (schedule.isHoliday &&
      (schedule.laborDayType === 'work' || schedule.dayType === 'working'))
  ) {
    return {
      kind: 'info',
      titleKey: 'work_status.holiday',
      titleDefault: 'Dia festiu',
      descriptionKey: 'work_status.holiday_description',
      descriptionDefault: schedule.holidayName
        ? `Avui és festiu: ${schedule.holidayName}.`
        : 'Avui és un dia festiu.',
    }
  }

  if (schedule.isAbsence || schedule.laborDayType === 'leave') {
    return {
      kind: 'info',
      titleKey: 'work_status.absence',
      titleDefault: 'Absència',
      descriptionKey: 'work_status.absence_description',
      descriptionDefault: 'Avui tens una absència o permís registrat.',
    }
  }

  if (!isWorkLaborDayInput(schedule)) {
    return {
      kind: 'info',
      titleKey: 'work_status.non_working',
      titleDefault: 'Dia no laborable',
      descriptionKey: 'work_status.non_working_description',
      descriptionDefault: 'Avui no tens jornada laboral assignada.',
    }
  }

  if (schedule.intervals.length === 0) {
    return {
      kind: 'info',
      titleKey: 'work_status.no_schedule',
      titleDefault: 'Sense horari',
      descriptionKey: 'work_status.no_schedule_description',
      descriptionDefault: 'No hi ha franges horàries definides per avui.',
    }
  }

  const punchedToday = hasPunchedToday(punches, now)
  const working = isWorkingPresence(presenceStatus)
  const out = isOutPresence(presenceStatus)
  const onPause = presenceStatus === 'on_pause'
  const phase = getSchedulePhase(schedule.intervals, now)

  if (phase.phase === 'before') {
    const firstStart = parseTimeOnDate(schedule.intervals[0]!.start, now)
    const minutes = minutesUntil(firstStart, now)

    if (working) {
      return {
        kind: 'success',
        titleKey: 'work_status.early_arrival',
        titleDefault: 'Entrada registrada',
        descriptionKey: 'work_status.early_arrival_description',
        descriptionDefault: 'Has fitxat abans de l\'inici de la jornada.',
      }
    }

    if (minutes <= soonThresholdMinutes) {
      return {
        kind: 'warning',
        titleKey: 'work_status.starting_soon',
        titleDefault: 'La jornada comença aviat',
        descriptionKey: 'work_status.starting_soon_description',
        descriptionDefault: 'La teva jornada comença en {{minutes}} min. Recorda fitxar.',
        descriptionParams: { minutes },
      }
    }

    return {
      kind: 'info',
      titleKey: 'work_status.before_work',
      titleDefault: 'Abans de l\'horari',
      descriptionKey: 'work_status.before_work_description',
      descriptionDefault: 'La teva jornada encara no ha començat.',
    }
  }

  if (phase.phase === 'slot') {
    const isAfternoon = phase.index > 0

    if (!punchedToday) {
      return {
        kind: 'error',
        titleKey: isAfternoon ? 'work_status.missing_afternoon_entry' : 'work_status.missing_entry',
        titleDefault: isAfternoon ? 'Falta fitxatge de tarda' : 'Falta fitxatge d\'entrada',
        descriptionKey: isAfternoon
          ? 'work_status.missing_afternoon_entry_description'
          : 'work_status.missing_entry_description',
        descriptionDefault: isAfternoon
          ? 'Hauries d\'haver fitxat l\'entrada de la tarda. Fes-ho ara.'
          : 'Hauries d\'haver fitxat l\'entrada. Fes-ho ara.',
      }
    }

    if (working) {
      return {
        kind: 'success',
        titleKey: isAfternoon ? 'work_status.working_afternoon' : 'work_status.working',
        titleDefault: isAfternoon ? 'Treballant (tarda)' : 'Treballant',
        descriptionKey: isAfternoon
          ? 'work_status.working_afternoon_description'
          : 'work_status.working_description',
        descriptionDefault: isAfternoon
          ? 'Estàs treballant segons l\'horari de la tarda.'
          : 'Estàs treballant segons l\'horari.',
      }
    }

    if (onPause) {
      return {
        kind: 'info',
        titleKey: 'work_status.on_pause',
        titleDefault: 'En pausa',
        descriptionKey: 'work_status.on_pause_description',
        descriptionDefault: 'Tens una pausa oberta durant l\'horari de treball.',
      }
    }

    if (out) {
      return {
        kind: 'warning',
        titleKey: isAfternoon ? 'work_status.unexpected_out_afternoon' : 'work_status.unexpected_out',
        titleDefault: 'Sortida no esperada',
        descriptionKey: isAfternoon
          ? 'work_status.unexpected_out_afternoon_description'
          : 'work_status.unexpected_out_description',
        descriptionDefault: isAfternoon
          ? 'Has fitxat sortida durant l\'horari de tarda.'
          : 'Has fitxat sortida durant l\'horari de treball. Si continues, recorda fitxar entrada.',
      }
    }
  }

  if (phase.phase === 'break') {
    const nextStart = parseTimeOnDate(schedule.intervals[phase.afterIndex + 1]!.start, now)
    const minutes = minutesUntil(nextStart, now)

    if (working) {
      return {
        kind: 'warning',
        titleKey: 'work_status.missing_morning_exit',
        titleDefault: 'Falta sortida de matí',
        descriptionKey: 'work_status.missing_morning_exit_description',
        descriptionDefault: 'No has fitxat la sortida del torn de matí. Si ja has acabat, fitxa sortida.',
      }
    }

    if (out || onPause) {
      if (minutes <= soonThresholdMinutes) {
        return {
          kind: 'warning',
          titleKey: 'work_status.afternoon_starting_soon',
          titleDefault: 'La tarda comença aviat',
          descriptionKey: 'work_status.afternoon_starting_soon_description',
          descriptionDefault: 'La sessió de tarda comença en {{minutes}} min. Recorda fitxar.',
          descriptionParams: { minutes },
        }
      }

      return {
        kind: 'success',
        titleKey: 'work_status.break_time',
        titleDefault: 'En descans',
        descriptionKey: 'work_status.break_description',
        descriptionDefault: 'Estàs en el període de descans entre sessions.',
      }
    }

    if (!punchedToday && minutes <= soonThresholdMinutes) {
      return {
        kind: 'warning',
        titleKey: 'work_status.afternoon_starting_soon',
        titleDefault: 'La tarda comença aviat',
        descriptionKey: 'work_status.afternoon_starting_soon_description',
        descriptionDefault: 'La sessió de tarda comença en {{minutes}} min. Recorda fitxar.',
        descriptionParams: { minutes },
      }
    }

    return {
      kind: 'info',
      titleKey: 'work_status.break_period',
      titleDefault: 'Període de descans',
      descriptionKey: 'work_status.break_period_description',
      descriptionDefault: 'Estàs en el descans entre el torn de matí i el de tarda.',
    }
  }

  // after last slot
  if (working || onPause) {
    return {
      kind: 'warning',
      titleKey: 'work_status.missing_exit',
      titleDefault: 'Falta fitxatge de sortida',
      descriptionKey: 'work_status.missing_exit_description',
      descriptionDefault: 'La jornada hauria d\'haver acabat. Recorda fitxar la sortida.',
    }
  }

  if (dayEnded(punches) || out) {
    return {
      kind: 'success',
      titleKey: 'work_status.day_complete',
      titleDefault: 'Jornada completada',
      descriptionKey: 'work_status.day_complete_description',
      descriptionDefault: 'Has completat la jornada d\'avui.',
    }
  }

  if (!punchedToday) {
    return {
      kind: 'warning',
      titleKey: 'work_status.no_punches_today',
      titleDefault: 'Sense fitxatges avui',
      descriptionKey: 'work_status.no_punches_description',
      descriptionDefault: 'No s\'ha registrat cap fitxatge avui.',
    }
  }

  return {
    kind: 'info',
    titleKey: 'work_status.after_work',
    titleDefault: 'Després de l\'horari',
    descriptionKey: 'work_status.after_work_description',
    descriptionDefault: 'L\'horari d\'avui ja ha acabat.',
  }
}
