import { buildDeviceInfo as buildAttendanceDeviceInfo } from '../utils/deviceInfo'

export interface GeoCapture {
  lat: number
  lng: number
  accuracy: number
  altitude?: number | null
  speed?: number | null
}

export interface GeoCaptureResult {
  geo: GeoCapture | null
  locationPermission: 'granted' | 'denied' | 'timeout' | 'error' | 'notrequired'
  geoError: string | null
}

const GEO_TIMEOUT_MS = 10_000

/** Captura geolocalització puntual amb timeout; mai llança excepció. */
export function captureGeoLocation(): Promise<GeoCaptureResult> {
  if (!navigator.geolocation) {
    return Promise.resolve({
      geo: null,
      locationPermission: 'notrequired',
      geoError: 'geolocation_not_supported',
    })
  }

  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      resolve({ geo: null, locationPermission: 'timeout', geoError: 'timeout' })
    }, GEO_TIMEOUT_MS)

    navigator.geolocation.getCurrentPosition(
      (pos) => {
        clearTimeout(timer)
        resolve({
          geo: {
            lat: pos.coords.latitude,
            lng: pos.coords.longitude,
            accuracy: pos.coords.accuracy,
            altitude: pos.coords.altitude,
            speed: pos.coords.speed,
          },
          locationPermission: 'granted',
          geoError: null,
        })
      },
      (err) => {
        clearTimeout(timer)
        const perm =
          err.code === err.PERMISSION_DENIED
            ? 'denied'
            : err.code === err.TIMEOUT
              ? 'timeout'
              : 'error'
        resolve({ geo: null, locationPermission: perm, geoError: err.message })
      },
      { enableHighAccuracy: true, timeout: GEO_TIMEOUT_MS, maximumAge: 0 },
    )
  })
}

export function buildDeviceInfo(): Record<string, string> {
  return buildAttendanceDeviceInfo('tenant_portal')
}
