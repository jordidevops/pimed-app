import { useCallback } from 'react'
import {
  reverseGeocodeWithNominatim,
  searchAddressWithNominatim,
  type GeocodeCandidate,
} from '../lib/maps/nominatim'

export function useGeocoding() {
  const searchAddress = useCallback(
    (query: string, language?: string, limit?: number): Promise<GeocodeCandidate[]> =>
      searchAddressWithNominatim(query, language, limit),
    [],
  )

  const reverseGeocode = useCallback(
    (lat: number, lng: number, language?: string): Promise<GeocodeCandidate | null> =>
      reverseGeocodeWithNominatim(lat, lng, language),
    [],
  )

  return {
    searchAddress,
    reverseGeocode,
  }
}
