import {
  buildPunchExportRows,
  downloadPunchesCsv,
  fetchSitePunchesInRange,
  type PunchExportRow,
} from '@/features/attendance/api/punchExportService'

export interface FetchStationDevicePunchesParams {
  siteId: string
  deviceId: string
  from: string
  to: string
  employeeId?: string
}

export async function fetchStationDevicePunches(params: FetchStationDevicePunchesParams) {
  return fetchSitePunchesInRange({
    siteId: params.siteId,
    deviceId: params.deviceId,
    from: params.from,
    to: params.to,
    employeeId: params.employeeId,
  })
}

export function exportStationDevicePunchesCsv(
  punches: Awaited<ReturnType<typeof fetchStationDevicePunches>>,
  employeeNames: Record<string, string>,
  siteName: string,
  stationName: string,
  from: string,
  to: string,
  headers: Record<keyof PunchExportRow, string>,
): void {
  const rows = buildPunchExportRows(punches, employeeNames, siteName)
  const slug = stationName.replace(/[^\w.-]+/g, '_').slice(0, 40) || 'estacio'
  downloadPunchesCsv(rows, headers, `fitxatges-${slug}_${from}_${to}`)
}
