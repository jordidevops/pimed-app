import { useCallback } from 'react'
import { useCalendarDisplaySettings } from '@/hooks/useCalendarDisplaySettings'
import { formatIsoDateWithPattern } from '@/lib/formatDatePattern'

export function useFormatAttendanceDate() {
  const { dateFormat } = useCalendarDisplaySettings()

  return useCallback(
    (iso: string | null | undefined) => {
      if (!iso) return '—'
      return formatIsoDateWithPattern(iso.slice(0, 10), dateFormat)
    },
    [dateFormat],
  )
}
