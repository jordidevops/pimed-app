export type GeoNoticeChoice = 'accepted' | 'declined'

const STORAGE_PREFIX = 'attendance_geo_notice_v1_'

export function geoNoticeStorageKey(tenantId: string): string {
  return `${STORAGE_PREFIX}${tenantId}`
}

export function getGeoNoticeChoice(tenantId: string): GeoNoticeChoice | null {
  try {
    const value = localStorage.getItem(geoNoticeStorageKey(tenantId))
    if (value === 'accepted' || value === 'declined') return value
  } catch {
    // Private browsing or storage blocked
  }
  return null
}

export function setGeoNoticeChoice(tenantId: string, choice: GeoNoticeChoice): void {
  try {
    localStorage.setItem(geoNoticeStorageKey(tenantId), choice)
  } catch {
    // Ignore quota / private mode
  }
}

export function hasSeenGeoNotice(tenantId: string): boolean {
  return getGeoNoticeChoice(tenantId) != null
}
