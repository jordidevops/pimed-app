import { useCallback, useState } from 'react'
import type { GeoPayload } from '@/lib/field-ops-db'

export type LocationPermission = 'granted' | 'denied' | 'timeout' | 'error' | 'notrequired'

interface GeoCaptureResult {
  geo: GeoPayload | null
  locationPermission: LocationPermission
}

interface UseGeoCaptureOptions {
  timeoutMs?: number
}

export function useGeoCapture(options?: UseGeoCaptureOptions) {
  const timeoutMs = options?.timeoutMs ?? 8000
  const [capturing, setCapturing] = useState(false)

  const capture = useCallback(async (): Promise<GeoCaptureResult> => {
    if (typeof navigator === 'undefined' || !('geolocation' in navigator)) {
      return { geo: null, locationPermission: 'notrequired' }
    }

    setCapturing(true)

    try {
      const pos = await new Promise<GeolocationPosition>((resolve, reject) => {
        let settled = false

        const finishResolve = (value: GeolocationPosition) => {
          if (settled) return
          settled = true
          clearTimeout(hardTimer)
          resolve(value)
        }

        const finishReject = (reason: unknown) => {
          if (settled) return
          settled = true
          clearTimeout(hardTimer)
          reject(reason)
        }

        const hardTimer = setTimeout(() => {
          finishReject(new Error('geo_hard_timeout'))
        }, timeoutMs)

        navigator.geolocation.getCurrentPosition(
          (position) => finishResolve(position),
          (error) => finishReject(error),
          {
            enableHighAccuracy: true,
            timeout: timeoutMs,
            maximumAge: 0,
          },
        )
      })

      return {
        geo: {
          latitude: pos.coords.latitude,
          longitude: pos.coords.longitude,
          accuracy_meters: pos.coords.accuracy,
          timestamp: new Date(pos.timestamp).toISOString(),
        },
        locationPermission: 'granted',
      }
    } catch (err) {
      if (err instanceof GeolocationPositionError) {
        if (err.code === err.PERMISSION_DENIED) return { geo: null, locationPermission: 'denied' }
        if (err.code === err.TIMEOUT) return { geo: null, locationPermission: 'timeout' }
      }
      if (err instanceof Error && err.message === 'geo_hard_timeout') {
        return { geo: null, locationPermission: 'timeout' }
      }
      return { geo: null, locationPermission: 'error' }
    } finally {
      setCapturing(false)
    }
  }, [timeoutMs])

  return { capture, capturing }
}
