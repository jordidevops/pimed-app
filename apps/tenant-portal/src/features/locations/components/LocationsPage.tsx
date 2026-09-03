import { useEffect, useMemo, useRef, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { APIProvider, Map as GoogleMap, Marker } from '@vis.gl/react-google-maps'
import { useMapsJsBrowserConfig } from '@/hooks/useMapsJsApiKey'
import {
  ChevronDown,
  ChevronRight,
  ChevronUp,
  ExternalLink,
  Gauge,
  GripVertical,
  Home,
  LocateFixed,
  MapPin,
  Plus,
  Search,
  Users,
  Wrench,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Input } from '@/components/ui/input'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useTenant } from '@/contexts/TenantContext'
import { useToast } from '@/hooks/use-toast'
import { useLocations } from '../api/useLocations'
import { useUpdateLocation } from '../api/useUpdateLocation'
import {
  getAncestors,
  getDescendantIds,
  normalizeLocError,
} from '../api/locationsService'
import type { Location, LocationUpdate } from '../api/locationsService'
import type { LocationStatus } from '../schemas/locationSchema'
import { useLocationOperationalData } from '../api/useLocationOperationalData'
import { LocationForm } from './LocationForm'
import { CreateFloorplanModal } from './CreateFloorplanModal'
import { LocationAttendanceEmployeesPanel } from './LocationAttendanceEmployeesPanel'
import { LocationLinkedStationsPanel } from './LocationLinkedStationsPanel'

const ROOT_KEY = '__root__'

type FloorplanPoint = {
  x: number
  y: number
}

type FloorplanRect = {
  x: number
  y: number
  width: number
  height: number
}

type FloorplanResizeCorner = 'nw' | 'ne' | 'sw' | 'se'

type FloorplanEditState =
  | {
      locationId: string
      mode: 'move'
      startClientX: number
      startClientY: number
      startRect: FloorplanRect
    }
  | {
      locationId: string
      mode: 'resize'
      corner: FloorplanResizeCorner
      startClientX: number
      startClientY: number
      startRect: FloorplanRect
    }

type GpsPoint = {
  lat: number
  lng: number
}

type ExternalMapMarker = {
  id: string
  kind: 'site' | 'location'
  name: string
  lat: number
  lng: number
  siteId: string | null
  locationId?: string
  source?: 'metadata' | 'derived'
  address?: string | null
}

const DEFAULT_RECT_WIDTH = 18
const DEFAULT_RECT_HEIGHT = 10
const MIN_RECT_WIDTH = 8
const MIN_RECT_HEIGHT = 6
const DEFAULT_MAP_LEVEL = '__default__'

function roundToTenths(value: number): number {
  return Math.round(value * 10) / 10
}

function clampFloorplanRect(rect: FloorplanRect): FloorplanRect {
  const width = clamp(rect.width, MIN_RECT_WIDTH, 100)
  const height = clamp(rect.height, MIN_RECT_HEIGHT, 100)
  const x = clamp(rect.x, 0, 100 - width)
  const y = clamp(rect.y, 0, 100 - height)
  return {
    x: roundToTenths(x),
    y: roundToTenths(y),
    width: roundToTenths(width),
    height: roundToTenths(height),
  }
}

function rectFromPoint(point: FloorplanPoint): FloorplanRect {
  return clampFloorplanRect({
    x: point.x - DEFAULT_RECT_WIDTH / 2,
    y: point.y - DEFAULT_RECT_HEIGHT / 2,
    width: DEFAULT_RECT_WIDTH,
    height: DEFAULT_RECT_HEIGHT,
  })
}

function hasRectChanged(a: FloorplanRect, b: FloorplanRect): boolean {
  return (
    Math.abs(a.x - b.x) > 0.05 ||
    Math.abs(a.y - b.y) > 0.05 ||
    Math.abs(a.width - b.width) > 0.05 ||
    Math.abs(a.height - b.height) > 0.05
  )
}

function clamp(value: number, min = 0, max = 100): number {
  if (value < min) return min
  if (value > max) return max
  return value
}

function asRecord(value: unknown): Record<string, unknown> | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null
  return value as Record<string, unknown>
}

function asFiniteNumber(value: unknown): number | null {
  if (typeof value === 'number' && Number.isFinite(value)) return value
  if (typeof value === 'string' && value.trim().length > 0) {
    const parsed = Number(value)
    if (Number.isFinite(parsed)) return parsed
  }
  return null
}

function extractCapacity(metadata: unknown): number | null {
  const obj = asRecord(metadata)
  if (!obj) return null
  const capacity = asFiniteNumber(obj.capacity)
  if (capacity === null || capacity <= 0) return null
  return Math.round(capacity)
}

function extractPointFromMetadata(metadata: unknown): FloorplanPoint | null {
  const obj = asRecord(metadata)
  if (!obj) return null

  const mapPosition = asRecord(obj.map_position)
  const x = asFiniteNumber(mapPosition?.x ?? obj.x)
  const y = asFiniteNumber(mapPosition?.y ?? obj.y)

  if (x === null || y === null) return null
  return { x: clamp(x), y: clamp(y) }
}

function extractPointFromGeo(geoCoordinates: unknown): FloorplanPoint | null {
  const geo = asRecord(geoCoordinates)
  if (!geo) return null

  const x = asFiniteNumber(geo.x)
  const y = asFiniteNumber(geo.y)
  if (x === null || y === null) return null

  return { x: clamp(x), y: clamp(y) }
}

function extractRectFromMetadata(metadata: unknown): FloorplanRect | null {
  const obj = asRecord(metadata)
  if (!obj) return null

  const mapRect = asRecord(obj.map_rect)
  const x = asFiniteNumber(mapRect?.x)
  const y = asFiniteNumber(mapRect?.y)
  const width = asFiniteNumber(mapRect?.width)
  const height = asFiniteNumber(mapRect?.height)

  if (x === null || y === null || width === null || height === null) return null

  return clampFloorplanRect({ x, y, width, height })
}

function extractMapLevel(metadata: unknown): string | null {
  const obj = asRecord(metadata)
  if (!obj) return null
  const raw = typeof obj.map_level === 'string' ? obj.map_level.trim() : ''
  return raw.length > 0 ? raw : null
}

function extractMapLevelLabel(metadata: unknown): string | null {
  const obj = asRecord(metadata)
  if (!obj) return null
  const raw = typeof obj.map_level_label === 'string' ? obj.map_level_label.trim() : ''
  return raw.length > 0 ? raw : null
}

function extractSortOrder(metadata: unknown): number | null {
  const obj = asRecord(metadata)
  if (!obj) return null
  const sortOrder = asFiniteNumber(obj.sort_order)
  if (sortOrder === null) return null
  return sortOrder
}

function extractLatLng(geoCoordinates: unknown): GpsPoint | null {
  const geo = asRecord(geoCoordinates)
  if (!geo) return null

  const lat = asFiniteNumber(geo.lat)
  const lng = asFiniteNumber(geo.lng)
  if (lat === null || lng === null) return null

  return { lat, lng }
}

function extractAddressFromGeo(geoCoordinates: unknown): string | null {
  const geo = asRecord(geoCoordinates)
  if (!geo) return null

  const geocoding = asRecord(geo.geocoding)
  const addressRaw = geocoding?.address ?? geo.address
  if (typeof addressRaw !== 'string') return null

  const normalized = addressRaw.trim()
  return normalized.length > 0 ? normalized : null
}

function extractSiteLatLngFromMetadata(metadata: unknown): GpsPoint | null {
  const obj = asRecord(metadata)
  if (!obj) return null

  const directLat = asFiniteNumber(obj.lat ?? obj.latitude)
  const directLng = asFiniteNumber(obj.lng ?? obj.lon ?? obj.long ?? obj.longitude)
  if (directLat !== null && directLng !== null) {
    return { lat: directLat, lng: directLng }
  }

  const nested = asRecord(obj.geo_coordinates ?? obj.coordinates ?? obj.location)
  if (!nested) return null

  const nestedLat = asFiniteNumber(nested.lat ?? nested.latitude)
  const nestedLng = asFiniteNumber(nested.lng ?? nested.lon ?? nested.long ?? nested.longitude)
  if (nestedLat === null || nestedLng === null) return null

  return { lat: nestedLat, lng: nestedLng }
}

function buildGoogleMapsUrl(gps: GpsPoint): string {
  return `https://www.google.com/maps?q=${gps.lat},${gps.lng}`
}

function getCornerHandleClass(corner: FloorplanResizeCorner): string {
  if (corner === 'nw') return '-left-1 -top-1 cursor-nwse-resize'
  if (corner === 'ne') return '-right-1 -top-1 cursor-nesw-resize'
  if (corner === 'sw') return '-left-1 -bottom-1 cursor-nesw-resize'
  return '-right-1 -bottom-1 cursor-nwse-resize'
}

export function LocationsPage() {
  const { t } = useTranslation('locations')
  const [searchParams, setSearchParams] = useSearchParams()
  const { activeTenant, tenants, tenantsLoading, activeSite, activeRole, sites, setSelectedSiteId } = useTenant()
  const { toast } = useToast()
  const { data: mapsJsConfig } = useMapsJsBrowserConfig(true)
  const mapsJsApiKey = mapsJsConfig?.apiKey
  const mapsJsMapId = mapsJsConfig?.mapId ?? undefined

  const { data: allLocations = [], isLoading, error } = useLocations()
  const {
    data: operationalData,
    isLoading: operationalLoading,
  } = useLocationOperationalData()

  const updateMutation = useUpdateLocation()

  // ─── Navigation & form state ───────────────────────────────────────────────
  const [selectedLocationId, setSelectedLocationId] = useState<string | null>(
    () => searchParams.get('locationId'),
  )
  const [expandedNodeIds, setExpandedNodeIds] = useState<Record<string, boolean>>({})
  const [searchTerm, setSearchTerm] = useState('')
  const [draftFloorplanRects, setDraftFloorplanRects] = useState<Record<string, FloorplanRect>>({})
  const [floorplanEditState, setFloorplanEditState] = useState<FloorplanEditState | null>(null)
  const [selectedMapLevel, setSelectedMapLevel] = useState<string>(DEFAULT_MAP_LEVEL)
  const [mapViewTab, setMapViewTab] = useState<'floorplans' | 'map'>('floorplans')
  const [createPlanModalOpen, setCreatePlanModalOpen] = useState(false)
  const [newFloorplanDraft, setNewFloorplanDraft] = useState('')
  const [customFloorplans, setCustomFloorplans] = useState<string[]>([])
  const [draggingLocationId, setDraggingLocationId] = useState<string | null>(null)
  const [hoverPlanId, setHoverPlanId] = useState<string | null>(null)
  const [pendingAssignment, setPendingAssignment] = useState<
    { locationId: string; planId: string } | null
  >(null)

  const [formOpen, setFormOpen] = useState(false)
  const [editTarget, setEditTarget] = useState<Location | null>(null)
  const [formDefaultParentId, setFormDefaultParentId] = useState<string | null>(null)
  const floorplanCanvasRef = useRef<HTMLDivElement | null>(null)

  const canManageFloorplan = activeRole === 'owner' || activeRole === 'manager'
  const canManageAttendanceAssignments = activeRole === 'owner' || activeRole === 'manager'
  const canReorder = activeRole === 'owner' || activeRole === 'manager'

  const selectedLocation = useMemo(
    () => allLocations.find((loc) => loc.id === selectedLocationId) ?? null,
    [allLocations, selectedLocationId],
  )

  useEffect(() => {
    const fromUrl = searchParams.get('locationId')
    if (fromUrl && fromUrl !== selectedLocationId) {
      setSelectedLocationId(fromUrl)
      const loc = allLocations.find((item) => item.id === fromUrl)
      if (loc?.site_id && loc.site_id !== activeSite?.id) {
        setSelectedSiteId(loc.site_id)
      }
    }
  }, [searchParams, allLocations, activeSite?.id, selectedLocationId, setSelectedSiteId])

  useEffect(() => {
    const current = searchParams.get('locationId')
    if (selectedLocationId && current !== selectedLocationId) {
      const next = new URLSearchParams(searchParams)
      next.set('locationId', selectedLocationId)
      setSearchParams(next, { replace: true })
    } else if (!selectedLocationId && current) {
      const next = new URLSearchParams(searchParams)
      next.delete('locationId')
      setSearchParams(next, { replace: true })
    }
  }, [selectedLocationId, searchParams, setSearchParams])

  const selectedAncestors = useMemo(
    () => getAncestors(allLocations, selectedLocationId),
    [allLocations, selectedLocationId],
  )

  const selectedAncestorIds = useMemo(() => {
    const ids = new Set<string>()
    for (const ancestor of selectedAncestors.slice(0, -1)) {
      if (ancestor.id) ids.add(ancestor.id)
    }
    return ids
  }, [selectedAncestors])

  const childrenByParentId = useMemo(() => {
    const map = new Map<string, Location[]>()
    for (const location of allLocations) {
      const parentKey = location.parent_id ?? ROOT_KEY
      const bucket = map.get(parentKey)
      if (!bucket) {
        map.set(parentKey, [location])
      } else {
        bucket.push(location)
      }
    }

    for (const bucket of map.values()) {
      bucket.sort((a, b) => {
        const sortA = extractSortOrder(a.metadata)
        const sortB = extractSortOrder(b.metadata)

        if (sortA !== null && sortB !== null && sortA !== sortB) return sortA - sortB
        if (sortA !== null && sortB === null) return -1
        if (sortA === null && sortB !== null) return 1

        return (a.name ?? '').localeCompare(b.name ?? '')
      })
    }
    return map
  }, [allLocations])

  const rootLocations = useMemo(
    () => childrenByParentId.get(ROOT_KEY) ?? [],
    [childrenByParentId],
  )

  const childrenCountMap = useMemo(() => {
    const map: Record<string, number> = {}
    for (const location of allLocations) {
      if (location.parent_id) {
        map[location.parent_id] = (map[location.parent_id] ?? 0) + 1
      }
    }
    return map
  }, [allLocations])

  const searchValue = searchTerm.trim().toLowerCase()
  const isSearching = searchValue.length > 0

  const visibleNodeIds = useMemo(() => {
    if (!isSearching) return null

    const visible = new Set<string>()
    for (const location of allLocations) {
      const locationId = location.id
      const locationName = (location.name ?? '').toLowerCase()
      if (!locationId || !locationName.includes(searchValue)) continue

      visible.add(locationId)

      const ancestors = getAncestors(allLocations, locationId)
      for (const ancestor of ancestors) {
        if (ancestor.id) visible.add(ancestor.id)
      }

      const descendants = getDescendantIds(allLocations, locationId)
      for (const descendantId of descendants) visible.add(descendantId)
    }
    return visible
  }, [allLocations, isSearching, searchValue])

  const selectedSubtreeIds = useMemo(() => {
    if (!selectedLocation?.id) return []
    return [selectedLocation.id, ...getDescendantIds(allLocations, selectedLocation.id)]
  }, [allLocations, selectedLocation])

  const selectedScopeSet = useMemo(() => new Set(selectedSubtreeIds), [selectedSubtreeIds])

  const baseFloorplanRects = useMemo(() => {
    const rects = new Map<string, FloorplanRect>()

    for (const location of allLocations) {
      if (!location.id) continue

      const fromRect = extractRectFromMetadata(location.metadata)
      if (fromRect) {
        rects.set(location.id, fromRect)
        continue
      }

      const fromMetadata = extractPointFromMetadata(location.metadata)
      if (fromMetadata) {
        rects.set(location.id, rectFromPoint(fromMetadata))
        continue
      }

      const fromGeoPoint = extractPointFromGeo(location.geo_coordinates)
      if (fromGeoPoint) {
        rects.set(location.id, rectFromPoint(fromGeoPoint))
      }
    }

    return rects
  }, [allLocations])

  const floorplanRects = useMemo(() => {
    const merged = new Map(baseFloorplanRects)
    for (const [locationId, rect] of Object.entries(draftFloorplanRects)) {
      merged.set(locationId, rect)
    }
    return merged
  }, [baseFloorplanRects, draftFloorplanRects])

  const gpsPointsByLocationId = useMemo(() => {
    const points = new Map<string, GpsPoint>()
    for (const location of allLocations) {
      if (!location.id) continue
      const latLng = extractLatLng(location.geo_coordinates)
      if (latLng) points.set(location.id, latLng)
    }
    return points
  }, [allLocations])

  const locationsWithFloorplanRect = useMemo(
    () => allLocations.filter((location) => location.id && floorplanRects.has(location.id)),
    [allLocations, floorplanRects],
  )

  const floorplanLevelByLocationId = useMemo(() => {
    const map = new Map<string, string>()
    for (const location of locationsWithFloorplanRect) {
      if (!location.id) continue
      map.set(location.id, extractMapLevel(location.metadata) ?? DEFAULT_MAP_LEVEL)
    }
    return map
  }, [locationsWithFloorplanRect])

  const floorplanLevelOptions = useMemo(() => {
    const options = new Map<string, { id: string; label: string; count: number }>()

    options.set(DEFAULT_MAP_LEVEL, {
      id: DEFAULT_MAP_LEVEL,
      label: t('locations.map.default_plan', 'General'),
      count: 0,
    })

    for (const location of locationsWithFloorplanRect) {
      if (!location.id) continue
      const levelId = floorplanLevelByLocationId.get(location.id) ?? DEFAULT_MAP_LEVEL
      const levelLabel =
        extractMapLevelLabel(location.metadata) ??
        (levelId === DEFAULT_MAP_LEVEL
          ? t('locations.map.default_plan', 'General')
          : levelId)

      const current = options.get(levelId)
      if (!current) {
        options.set(levelId, { id: levelId, label: levelLabel, count: 1 })
      } else {
        current.count += 1
      }
    }

    for (const planId of customFloorplans) {
      if (!options.has(planId)) {
        options.set(planId, { id: planId, label: planId, count: 0 })
      }
    }

    return Array.from(options.values()).sort((a, b) => {
      if (a.id === DEFAULT_MAP_LEVEL) return -1
      if (b.id === DEFAULT_MAP_LEVEL) return 1
      return a.label.localeCompare(b.label)
    })
  }, [customFloorplans, floorplanLevelByLocationId, locationsWithFloorplanRect, t])

  const visibleFloorplanLocations = useMemo(
    () =>
      locationsWithFloorplanRect.filter((location) => {
        if (!location.id) return false
        return (floorplanLevelByLocationId.get(location.id) ?? DEFAULT_MAP_LEVEL) === selectedMapLevel
      }),
    [floorplanLevelByLocationId, locationsWithFloorplanRect, selectedMapLevel],
  )

  const externalGpsLocations = useMemo(
    () => allLocations.filter((location) => location.id && gpsPointsByLocationId.has(location.id)),
    [allLocations, gpsPointsByLocationId],
  )

  const gpsLocationsBySiteId = useMemo(() => {
    const map = new Map<string, GpsPoint[]>()
    for (const location of externalGpsLocations) {
      if (!location.id || !location.site_id) continue
      const point = gpsPointsByLocationId.get(location.id)
      if (!point) continue

      const bucket = map.get(location.site_id)
      if (!bucket) {
        map.set(location.site_id, [point])
      } else {
        bucket.push(point)
      }
    }
    return map
  }, [externalGpsLocations, gpsPointsByLocationId])

  const siteMapPoints = useMemo(() => {
    const map = new Map<string, { point: GpsPoint; source: 'metadata' | 'derived' }>()
    for (const site of sites) {
      const metadataPoint = extractSiteLatLngFromMetadata(site.metadata)
      if (metadataPoint) {
        map.set(site.id, { point: metadataPoint, source: 'metadata' })
        continue
      }

      const derivedPoints = gpsLocationsBySiteId.get(site.id) ?? []
      if (derivedPoints.length === 0) continue

      const avgLat = derivedPoints.reduce((sum, point) => sum + point.lat, 0) / derivedPoints.length
      const avgLng = derivedPoints.reduce((sum, point) => sum + point.lng, 0) / derivedPoints.length
      map.set(site.id, {
        point: { lat: avgLat, lng: avgLng },
        source: 'derived',
      })
    }
    return map
  }, [gpsLocationsBySiteId, sites])

  const siteById = useMemo(() => {
    const map = new Map<string, (typeof sites)[number]>()
    for (const site of sites) {
      map.set(site.id, site)
    }
    return map
  }, [sites])

  const externalMapMarkers = useMemo<ExternalMapMarker[]>(() => {
    const markers: ExternalMapMarker[] = []

    for (const site of sites) {
      const sitePoint = siteMapPoints.get(site.id)
      if (!sitePoint) continue

      markers.push({
        id: `site-${site.id}`,
        kind: 'site',
        name: site.name,
        lat: sitePoint.point.lat,
        lng: sitePoint.point.lng,
        siteId: site.id,
        source: sitePoint.source,
        address: site.address,
      })
    }

    for (const location of externalGpsLocations) {
      if (!location.id) continue
      const point = gpsPointsByLocationId.get(location.id)
      if (!point) continue

      markers.push({
        id: `location-${location.id}`,
        kind: 'location',
        name: location.name ?? t('locations.common.not_available', 'N/D'),
        lat: point.lat,
        lng: point.lng,
        siteId: location.site_id,
        locationId: location.id,
        address: extractAddressFromGeo(location.geo_coordinates),
      })
    }

    return markers
  }, [externalGpsLocations, gpsPointsByLocationId, siteMapPoints, sites, t])

  const externalMapCenter = useMemo<[number, number] | null>(() => {
    if (externalMapMarkers.length === 0) return null

    const selectedMarker = externalMapMarkers.find(
      (marker) => marker.kind === 'location' && marker.locationId === selectedLocationId,
    )
    if (selectedMarker) return [selectedMarker.lat, selectedMarker.lng]

    if (activeSite?.id) {
      const activeSiteMarker = externalMapMarkers.find(
        (marker) => marker.kind === 'site' && marker.siteId === activeSite.id,
      )
      if (activeSiteMarker) return [activeSiteMarker.lat, activeSiteMarker.lng]
    }

    const avgLat =
      externalMapMarkers.reduce((sum, marker) => sum + marker.lat, 0) / externalMapMarkers.length
    const avgLng =
      externalMapMarkers.reduce((sum, marker) => sum + marker.lng, 0) / externalMapMarkers.length

    return [avgLat, avgLng]
  }, [activeSite?.id, externalMapMarkers, selectedLocationId])

  const externalMapKey = useMemo(() => {
    if (!externalMapCenter) return 'external-map-empty'
    return `external-map-${externalMapCenter[0]}-${externalMapCenter[1]}-${externalMapMarkers.length}`
  }, [externalMapCenter, externalMapMarkers.length])

  const locationsWithoutPoint = useMemo(
    () =>
      allLocations.filter(
        (location) =>
          !location.id ||
          (!floorplanRects.has(location.id) && !gpsPointsByLocationId.has(location.id)),
      ),
    [allLocations, floorplanRects, gpsPointsByLocationId],
  )

  const locationById = useMemo(() => {
    const map = new Map<string, Location>()
    for (const location of allLocations) {
      if (location.id) map.set(location.id, location)
    }
    return map
  }, [allLocations])

  const assets = operationalData?.assets ?? []
  const projects = operationalData?.projects ?? []
  const openWorkLogs = operationalData?.openWorkLogs ?? []

  const assetsInScope = useMemo(
    () =>
      assets.filter(
        (asset) =>
          !!asset.location_id &&
          selectedScopeSet.has(asset.location_id) &&
          (!activeSite?.id || asset.site_id === activeSite.id),
      ),
    [activeSite?.id, assets, selectedScopeSet],
  )

  const projectsInScope = useMemo(
    () =>
      projects.filter(
        (project) =>
          !!project.location_id &&
          selectedScopeSet.has(project.location_id) &&
          (!activeSite?.id || project.site_id === activeSite.id),
      ),
    [activeSite?.id, projects, selectedScopeSet],
  )

  const activeProjectsCount = useMemo(
    () =>
      projectsInScope.filter((project) => {
        const status = (project.status ?? '').toLowerCase()
        return !['closed', 'done', 'completed', 'cancelled', 'canceled', 'archived'].includes(status)
      }).length,
    [projectsInScope],
  )

  const projectIdsInScope = useMemo(() => {
    const ids = new Set<string>()
    for (const project of projectsInScope) {
      if (project.id) ids.add(project.id)
    }
    return ids
  }, [projectsInScope])

  const openWorkLogsInScope = useMemo(
    () =>
      openWorkLogs.filter(
        (workLog) => !!workLog.project_id && projectIdsInScope.has(workLog.project_id),
      ),
    [openWorkLogs, projectIdsInScope],
  )

  const estimatedOccupancy = useMemo(() => {
    const workers = new Set<string>()
    for (const workLog of openWorkLogsInScope) {
      if (workLog.worker_id) workers.add(workLog.worker_id)
    }
    return workers.size
  }, [openWorkLogsInScope])

  const maximumCapacity = useMemo(
    () => extractCapacity(selectedLocation?.metadata),
    [selectedLocation?.metadata],
  )

  const usagePercent = useMemo(() => {
    if (!maximumCapacity || maximumCapacity <= 0) return null
    return Math.round((estimatedOccupancy / maximumCapacity) * 100)
  }, [estimatedOccupancy, maximumCapacity])

  const assetCounts = useMemo(() => {
    const counts = {
      operational: 0,
      repairing: 0,
      down: 0,
      retired: 0,
      other: 0,
    }

    for (const asset of assetsInScope) {
      const status = (asset.status ?? '').toLowerCase()
      if (status === 'operational') counts.operational += 1
      else if (status === 'repairing') counts.repairing += 1
      else if (status === 'down') counts.down += 1
      else if (status === 'retired') counts.retired += 1
      else counts.other += 1
    }

    return counts
  }, [assetsInScope])

  useEffect(() => {
    if (!selectedLocationId) return
    const exists = allLocations.some((location) => location.id === selectedLocationId)
    if (!exists) setSelectedLocationId(null)
  }, [allLocations, selectedLocationId])

  useEffect(() => {
    if (selectedLocationId || allLocations.length === 0) return
    setSelectedLocationId(allLocations[0].id ?? null)
  }, [allLocations, selectedLocationId])

  useEffect(() => {
    if (activeSite) return
    setSelectedLocationId(null)
    setExpandedNodeIds({})
    setSearchTerm('')
    setSelectedMapLevel(DEFAULT_MAP_LEVEL)
    setDraftFloorplanRects({})
    setFloorplanEditState(null)
    setNewFloorplanDraft('')
    setCustomFloorplans([])
    setDraggingLocationId(null)
    setHoverPlanId(null)
    setPendingAssignment(null)
  }, [activeSite])

  useEffect(() => {
    if (!activeSite?.id) return

    try {
      const storageKey = `locations-floorplans-${activeSite.id}`
      const raw = window.localStorage.getItem(storageKey)
      if (!raw) {
        setCustomFloorplans([])
        return
      }

      const parsed = JSON.parse(raw)
      if (Array.isArray(parsed)) {
        const clean = parsed.filter((item) => typeof item === 'string' && item.trim().length > 0)
        setCustomFloorplans(clean)
      } else {
        setCustomFloorplans([])
      }
    } catch {
      setCustomFloorplans([])
    }
  }, [activeSite?.id])

  useEffect(() => {
    if (!activeSite?.id) return
    const storageKey = `locations-floorplans-${activeSite.id}`
    window.localStorage.setItem(storageKey, JSON.stringify(customFloorplans))
  }, [activeSite?.id, customFloorplans])

  useEffect(() => {
    if (floorplanLevelOptions.length === 0) {
      setSelectedMapLevel(DEFAULT_MAP_LEVEL)
      return
    }

    const levelIds = new Set(floorplanLevelOptions.map((level) => level.id))
    if (!levelIds.has(selectedMapLevel)) {
      setSelectedMapLevel(floorplanLevelOptions[0].id)
    }
  }, [
    floorplanLevelOptions,
    selectedMapLevel,
  ])

  useEffect(() => {
    setDraftFloorplanRects((prev) => {
      let changed = false
      const next: Record<string, FloorplanRect> = {}
      for (const [locationId, rect] of Object.entries(prev)) {
        if (!locationById.has(locationId)) {
          changed = true
          continue
        }

        const persistedRect = baseFloorplanRects.get(locationId)
        if (persistedRect && !hasRectChanged(persistedRect, rect)) {
          changed = true
          continue
        }

        next[locationId] = rect
      }
      return changed ? next : prev
    })
  }, [baseFloorplanRects, locationById])

  function canEditFloorplan(location: Location): boolean {
    return !!activeSite?.id && canManageFloorplan && location.site_id === activeSite.id
  }

  function handleCreateFloorplan() {
    const nextPlan = newFloorplanDraft.trim()
    if (!nextPlan) return

    setCustomFloorplans((prev) => (prev.includes(nextPlan) ? prev : [...prev, nextPlan]))
    setSelectedMapLevel(nextPlan)
    setNewFloorplanDraft('')

    toast({
      description: t('locations.map.plan_created', 'Plànol creat. Ara pots assignar-hi zones arrossegant-les.'),
    })
  }

  function handleStartAssignDrag(event: React.DragEvent<HTMLElement>, location: Location) {
    if (!location.id || !canEditFloorplan(location)) return
    event.dataTransfer.effectAllowed = 'move'
    event.dataTransfer.setData('text/plain', location.id)
    setDraggingLocationId(location.id)
  }

  function handlePlanDragOver(event: React.DragEvent<HTMLElement>, planId: string) {
    if (!draggingLocationId || !canManageFloorplan) return
    event.preventDefault()
    event.dataTransfer.dropEffect = 'move'
    setHoverPlanId(planId)
  }

  function handlePlanDrop(event: React.DragEvent<HTMLElement>, planId: string) {
    if (!draggingLocationId) return
    event.preventDefault()
    event.stopPropagation()
    setHoverPlanId(null)
    setPendingAssignment({ locationId: draggingLocationId, planId })
  }

  function handleFloorplanCanvasDragOver(event: React.DragEvent<HTMLElement>) {
    if (!draggingLocationId || !canManageFloorplan) return
    event.preventDefault()
    event.dataTransfer.dropEffect = 'move'
  }

  function handleFloorplanCanvasDrop(event: React.DragEvent<HTMLElement>) {
    if (!draggingLocationId || !canManageFloorplan) return
    event.preventDefault()
    event.stopPropagation()

    const canvas = floorplanCanvasRef.current
    if (!canvas) return

    const location = locationById.get(draggingLocationId)
    if (!location || !location.id || !canEditFloorplan(location)) return

    const rect = canvas.getBoundingClientRect()
    const x = ((event.clientX - rect.left) / rect.width) * 100
    const y = ((event.clientY - rect.top) / rect.height) * 100

    const metadataBase = { ...(asRecord(location.metadata) ?? {}) } as Record<string, unknown>
    metadataBase.map_level = selectedMapLevel
    metadataBase.map_position = {
      x: Math.max(0, Math.min(100, x)),
      y: Math.max(0, Math.min(100, y)),
    }

    updateMutation
      .mutateAsync({
        id: location.id,
        params: {
          metadata: metadataBase as LocationUpdate['metadata'],
        },
      })
      .then(() => {
        setDraggingLocationId(null)
        toast({
          description: t('locations.map.zone_positioned', 'Zona posicionada al plànol.'),
        })
      })
      .catch((err) => {
        const kind = normalizeLocError(err)
        toast({
          variant: 'destructive',
          description:
            kind === 'unauthorized'
              ? t('locations.errors.unauthorized', 'No tens permís per fer aquesta acció')
              : t('locations.map.edit_save_failed', 'No s\'ha pogut desar la posició de la zona.'),
        })
      })
  }

  async function handleConfirmAssignToPlan() {
    if (!pendingAssignment) return

    const location = locationById.get(pendingAssignment.locationId)
    if (!location || !location.id) {
      setPendingAssignment(null)
      return
    }

    if (!canEditFloorplan(location)) {
      toast({
        variant: 'destructive',
        description: t('locations.errors.unauthorized', 'No tens permís per fer aquesta acció'),
      })
      setPendingAssignment(null)
      return
    }

    const metadataBase = { ...(asRecord(location.metadata) ?? {}) } as Record<string, unknown>
    if (pendingAssignment.planId === DEFAULT_MAP_LEVEL) {
      delete metadataBase.map_level
    } else {
      metadataBase.map_level = pendingAssignment.planId
      setCustomFloorplans((prev) =>
        prev.includes(pendingAssignment.planId) ? prev : [...prev, pendingAssignment.planId],
      )
    }

    try {
      await updateMutation.mutateAsync({
        id: location.id,
        params: {
          metadata: metadataBase as LocationUpdate['metadata'],
        },
      })

      setSelectedMapLevel(pendingAssignment.planId)
      setPendingAssignment(null)
      setDraggingLocationId(null)

      toast({
        description: t('locations.map.zone_assigned_to_plan', 'Zona assignada al plànol.'),
      })
    } catch (err) {
      const kind = normalizeLocError(err)
      toast({
        variant: 'destructive',
        description:
          kind === 'unauthorized'
            ? t('locations.errors.unauthorized', 'No tens permís per fer aquesta acció')
            : t('locations.map.edit_save_failed', 'No s\'ha pogut desar el rectangle de la zona.'),
      })
    }
  }

  // ─── Handlers ──────────────────────────────────────────────────────────────
  function handleSelectLocation(location: Location) {
    if (!location.id) return
    setSelectedLocationId(location.id)

    const locationLevel = extractMapLevel(location.metadata) ?? DEFAULT_MAP_LEVEL
    setSelectedMapLevel(locationLevel)

    const childrenCount = childrenByParentId.get(location.id)?.length ?? 0
    if (childrenCount > 0) {
      setExpandedNodeIds((prev) => ({
        ...prev,
        [location.id!]: prev[location.id!] ?? true,
      }))
    }

    if (location.parent_id) {
      setExpandedNodeIds((prev) => ({
        ...prev,
        [location.parent_id!]: true,
      }))
    }
  }

  function handleToggleExpand(locationId: string) {
    setExpandedNodeIds((prev) => ({
      ...prev,
      [locationId]: !prev[locationId],
    }))
  }

  function handleOpenCreate() {
    setEditTarget(null)
    setFormDefaultParentId(selectedLocationId)
    setFormOpen(true)
  }

  function handleEdit(loc: Location) {
    setEditTarget(loc)
    setFormDefaultParentId(null)
    setFormOpen(true)
  }

  function handleAddChild(loc: Location) {
    setEditTarget(null)
    setFormDefaultParentId(loc.id ?? null)
    if (loc.id) {
      setSelectedLocationId(loc.id)
      setExpandedNodeIds((prev) => ({
        ...prev,
        [loc.id!]: true,
      }))
    }
    setFormOpen(true)
  }

  async function handleToggleStatus(loc: Location) {
    const current = (loc.status ?? 'active') as LocationStatus
    const next: LocationStatus = current === 'active' ? 'inactive' : 'active'
    try {
      await updateMutation.mutateAsync({ id: loc.id!, params: { status: next } })
      toast({
        description:
          next === 'active'
            ? t('locations.toast.activated', 'Ubicació activada')
            : t('locations.toast.deactivated', 'Ubicació desactivada'),
      })
    } catch (err) {
      const kind = normalizeLocError(err)
      toast({
        variant: 'destructive',
        description:
          kind === 'unauthorized'
            ? t('locations.errors.unauthorized', 'No tens permís per fer aquesta acció')
            : t('locations.errors.toggle_failed', "Error en canviar l'estat"),
      })
    }
  }

  async function handleMoveNode(loc: Location, direction: 'up' | 'down') {
    if (!loc.id || !canReorder) return

    const parentKey = loc.parent_id ?? ROOT_KEY
    const siblings = childrenByParentId.get(parentKey) ?? []
    const currentIndex = siblings.findIndex((item) => item.id === loc.id)
    if (currentIndex < 0) return

    const targetIndex = direction === 'up' ? currentIndex - 1 : currentIndex + 1
    if (targetIndex < 0 || targetIndex >= siblings.length) return

    const current = siblings[currentIndex]
    const target = siblings[targetIndex]
    if (!current.id || !target.id) return

    if (!activeSite?.id || current.site_id !== activeSite.id || target.site_id !== activeSite.id) {
      toast({
        variant: 'destructive',
        description: t('locations.errors.unauthorized', 'No tens permís per fer aquesta acció'),
      })
      return
    }

    const currentMetadata = { ...(asRecord(current.metadata) ?? {}) } as Record<string, unknown>
    const targetMetadata = { ...(asRecord(target.metadata) ?? {}) } as Record<string, unknown>

    const currentOrder = extractSortOrder(current.metadata) ?? currentIndex * 1000
    const targetOrder = extractSortOrder(target.metadata) ?? targetIndex * 1000

    currentMetadata.sort_order = targetOrder
    targetMetadata.sort_order = currentOrder

    try {
      await Promise.all([
        updateMutation.mutateAsync({
          id: current.id,
          params: { metadata: currentMetadata as LocationUpdate['metadata'] },
        }),
        updateMutation.mutateAsync({
          id: target.id,
          params: { metadata: targetMetadata as LocationUpdate['metadata'] },
        }),
      ])

      toast({
        description: t('locations.toast.reordered', 'Ordre de l\'arbre actualitzat'),
      })
    } catch (err) {
      const kind = normalizeLocError(err)
      toast({
        variant: 'destructive',
        description:
          kind === 'unauthorized'
            ? t('locations.errors.unauthorized', 'No tens permís per fer aquesta acció')
            : t('locations.errors.reorder_failed', 'No s\'ha pogut reordenar la ubicació'),
      })
    }
  }

  function handleStartFloorplanEdit(
    event: React.PointerEvent<HTMLElement>,
    location: Location,
    mode: FloorplanEditState['mode'],
    corner?: FloorplanResizeCorner,
  ) {
    if (!location.id || !canEditFloorplan(location)) return

    const baseRect = floorplanRects.get(location.id)
    if (!baseRect) return

    event.preventDefault()
    event.stopPropagation()

    setSelectedLocationId(location.id)
    setDraftFloorplanRects((prev) => ({
      ...prev,
      [location.id!]: baseRect,
    }))

    if (mode === 'resize' && corner) {
      setFloorplanEditState({
        locationId: location.id,
        mode: 'resize',
        corner,
        startClientX: event.clientX,
        startClientY: event.clientY,
        startRect: baseRect,
      })
      return
    }

    setFloorplanEditState({
      locationId: location.id,
      mode: 'move',
      startClientX: event.clientX,
      startClientY: event.clientY,
      startRect: baseRect,
    })
  }

  useEffect(() => {
    if (!floorplanEditState) return
    const session = floorplanEditState

    function onPointerMove(event: PointerEvent) {
      const canvas = floorplanCanvasRef.current
      if (!canvas) return

      const canvasRect = canvas.getBoundingClientRect()
      if (canvasRect.width <= 0 || canvasRect.height <= 0) return

      const deltaXPercent = ((event.clientX - session.startClientX) / canvasRect.width) * 100
      const deltaYPercent = ((event.clientY - session.startClientY) / canvasRect.height) * 100

      const { startRect } = session
      let nextRect: FloorplanRect

      if (session.mode === 'resize') {
        const resizeByCorner: Record<FloorplanResizeCorner, FloorplanRect> = {
          se: {
            x: startRect.x,
            y: startRect.y,
            width: startRect.width + deltaXPercent,
            height: startRect.height + deltaYPercent,
          },
          sw: {
            x: startRect.x + deltaXPercent,
            y: startRect.y,
            width: startRect.width - deltaXPercent,
            height: startRect.height + deltaYPercent,
          },
          ne: {
            x: startRect.x,
            y: startRect.y + deltaYPercent,
            width: startRect.width + deltaXPercent,
            height: startRect.height - deltaYPercent,
          },
          nw: {
            x: startRect.x + deltaXPercent,
            y: startRect.y + deltaYPercent,
            width: startRect.width - deltaXPercent,
            height: startRect.height - deltaYPercent,
          },
        }

        nextRect = clampFloorplanRect(resizeByCorner[session.corner])
      } else {
        nextRect = clampFloorplanRect({
          x: startRect.x + deltaXPercent,
          y: startRect.y + deltaYPercent,
          width: startRect.width,
          height: startRect.height,
        })
      }

      setDraftFloorplanRects((prev) => ({
        ...prev,
        [session.locationId]: nextRect,
      }))
    }

    function onPointerUp() {
      setFloorplanEditState(null)

      const location = locationById.get(session.locationId)
      if (!location || !location.id) return
      if (!canEditFloorplan(location)) return

      const finalRect = draftFloorplanRects[session.locationId] ?? session.startRect
      if (!hasRectChanged(session.startRect, finalRect)) {
        setDraftFloorplanRects((prev) => {
          const next = { ...prev }
          delete next[session.locationId]
          return next
        })
        return
      }

      const metadataBase = asRecord(location.metadata) ?? {}
      const payloadRect = clampFloorplanRect(finalRect)
      const payload = {
        ...metadataBase,
        map_position: {
          x: roundToTenths(payloadRect.x + payloadRect.width / 2),
          y: roundToTenths(payloadRect.y + payloadRect.height / 2),
        },
        map_rect: payloadRect,
      }

      updateMutation
        .mutateAsync({
          id: session.locationId,
          params: {
            metadata: payload,
          },
        })
        .catch((err) => {
          setDraftFloorplanRects((prev) => ({
            ...prev,
            [session.locationId]: session.startRect,
          }))

          const kind = normalizeLocError(err)
          toast({
            variant: 'destructive',
            description:
              kind === 'unauthorized'
                ? t('locations.errors.unauthorized', 'No tens permís per fer aquesta acció')
                : t('locations.map.edit_save_failed', 'No s\'ha pogut desar el rectangle de la zona.'),
          })
        })
    }

    window.addEventListener('pointermove', onPointerMove)
    window.addEventListener('pointerup', onPointerUp)

    return () => {
      window.removeEventListener('pointermove', onPointerMove)
      window.removeEventListener('pointerup', onPointerUp)
    }
  }, [
    canManageFloorplan,
    draftFloorplanRects,
    floorplanEditState,
    locationById,
    updateMutation,
    activeSite?.id,
    t,
    toast,
  ])

  // ─── Guards ────────────────────────────────────────────────────────────────
  if (tenantsLoading || isLoading) {
    return (
      <div className="flex items-center justify-center h-64">
        <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-primary" />
      </div>
    )
  }

  if (!activeTenant && tenants.length > 1) {
    return (
      <div className="max-w-3xl mx-auto px-4 py-10">
        <div className="bg-amber-50 border border-amber-200 rounded-2xl p-6 text-center">
          <p className="text-sm text-amber-800 font-medium">
            {t('locations.errors.no_tenant', 'Selecciona una organització per veure les ubicacions')}
          </p>
        </div>
      </div>
    )
  }

  if (!activeTenant) return null

  if (error) {
    return (
      <div className="max-w-3xl mx-auto px-4 py-10">
        <div className="bg-destructive/10 border border-destructive/30 rounded-2xl p-6 text-center">
          <p className="text-sm text-destructive font-medium">
            {t('locations.errors.load_failed', 'Error en carregar les ubicacions')}
          </p>
        </div>
      </div>
    )
  }

  function renderTreeNode(location: Location, depth: number): React.ReactNode {
    if (!location.id) return null
    if (visibleNodeIds && !visibleNodeIds.has(location.id)) return null

    const children = childrenByParentId.get(location.id) ?? []
    const hasChildren = children.length > 0
    const isExpanded =
      isSearching ||
      expandedNodeIds[location.id] ||
      selectedAncestorIds.has(location.id)

    const isSelected = selectedLocationId === location.id
    const isWritable = !!activeSite?.id && location.site_id === activeSite.id
    const parentKey = location.parent_id ?? ROOT_KEY
    const siblings = childrenByParentId.get(parentKey) ?? []
    const siblingIndex = siblings.findIndex((item) => item.id === location.id)
    const canMoveUp = isWritable && canReorder && siblingIndex > 0
    const canMoveDown = isWritable && canReorder && siblingIndex >= 0 && siblingIndex < siblings.length - 1

    return (
      <li key={location.id} className="space-y-1">
        <div
          className={`group flex items-center gap-1 rounded-lg border px-2 py-1.5 transition-colors ${
            isSelected
              ? 'border-primary/50 bg-primary/5'
              : 'border-transparent hover:bg-accent/40'
          }`}
          style={{ paddingLeft: `${depth * 14 + 8}px` }}
        >
          {depth > 0 && <span className="h-5 w-px bg-border/70 mr-1" aria-hidden />}

          <button
            type="button"
            className={`h-6 w-6 shrink-0 rounded-md text-muted-foreground transition-colors ${
              hasChildren
                ? 'hover:bg-background hover:text-foreground'
                : 'cursor-default opacity-40'
            }`}
            onClick={() => hasChildren && handleToggleExpand(location.id!)}
            aria-label={
              hasChildren
                ? isExpanded
                  ? t('locations.tree.collapse', 'Contraure branca')
                  : t('locations.tree.expand', 'Expandir branca')
                : t('locations.tree.leaf', 'Node final')
            }
            disabled={!hasChildren}
          >
            {hasChildren ? (
              isExpanded ? (
                <ChevronDown className="mx-auto h-3.5 w-3.5" aria-hidden />
              ) : (
                <ChevronRight className="mx-auto h-3.5 w-3.5" aria-hidden />
              )
            ) : null}
          </button>

          <button
            type="button"
            onClick={() => handleSelectLocation(location)}
            className="min-w-0 flex-1 text-left"
            title={t('locations.actions.select', 'Seleccionar zona')}
          >
            <p className="truncate text-sm font-medium text-foreground">
              {location.name ?? t('locations.common.not_available', 'N/D')}
            </p>
            <div className="mt-0.5 flex items-center gap-1.5 text-[11px] text-muted-foreground">
              <span>
                {t(`locations.type.${location.type ?? 'other'}`, location.type ?? 'other')}
              </span>
              <span aria-hidden>•</span>
              <span>
                {t(`locations.status.${location.status ?? 'inactive'}`, location.status ?? 'inactive')}
              </span>
              {childrenCountMap[location.id] ? (
                <>
                  <span aria-hidden>•</span>
                  <span>
                    {t('locations.children_count', '{{count}} sububicacions', {
                      count: childrenCountMap[location.id] ?? 0,
                    })}
                  </span>
                </>
              ) : null}
            </div>
          </button>

          {isWritable && (
            <div className="flex items-center gap-0.5 opacity-0 transition-opacity group-hover:opacity-100">
              {canReorder && (
                <>
                  <Button
                    variant="ghost"
                    size="sm"
                    className="h-7 w-7 p-0"
                    onClick={() => handleMoveNode(location, 'up')}
                    disabled={!canMoveUp || updateMutation.isPending}
                    title={t('locations.actions.move_up', 'Moure amunt')}
                  >
                    <ChevronUp className="h-3.5 w-3.5" aria-hidden />
                  </Button>
                  <Button
                    variant="ghost"
                    size="sm"
                    className="h-7 w-7 p-0"
                    onClick={() => handleMoveNode(location, 'down')}
                    disabled={!canMoveDown || updateMutation.isPending}
                    title={t('locations.actions.move_down', 'Moure avall')}
                  >
                    <ChevronDown className="h-3.5 w-3.5" aria-hidden />
                  </Button>
                </>
              )}
              {canManageFloorplan && (
                <Button
                  variant="ghost"
                  size="sm"
                  className="h-7 w-7 p-0 cursor-grab active:cursor-grabbing"
                  draggable
                  onDragStart={(event) => handleStartAssignDrag(event, location)}
                  onDragEnd={() => {
                    setDraggingLocationId(null)
                    setHoverPlanId(null)
                  }}
                  title={t('locations.map.drag_zone_to_plan', 'Arrossegar zona al plànol')}
                >
                  <GripVertical className="h-3.5 w-3.5" aria-hidden />
                </Button>
              )}
              <Button
                variant="ghost"
                size="sm"
                className="h-7 w-7 p-0"
                onClick={() => handleEdit(location)}
                title={t('locations.actions.edit', 'Editar')}
              >
                <MapPin className="h-3.5 w-3.5" aria-hidden />
              </Button>
              <Button
                variant="ghost"
                size="sm"
                className="h-7 w-7 p-0"
                onClick={() => handleAddChild(location)}
                title={t('locations.actions.add_child', 'Afegir sububicació')}
              >
                <Plus className="h-3.5 w-3.5" aria-hidden />
              </Button>
            </div>
          )}
        </div>

        {hasChildren && isExpanded && (
          <ul className="space-y-1">
            {children.map((child) => renderTreeNode(child, depth + 1))}
          </ul>
        )}
      </li>
    )
  }

  const pendingAssignmentLocation = pendingAssignment
    ? locationById.get(pendingAssignment.locationId) ?? null
    : null
  const pendingAssignmentPlanLabel = pendingAssignment
    ? floorplanLevelOptions.find((option) => option.id === pendingAssignment.planId)?.label ??
      pendingAssignment.planId
    : ''

  // ─── Render ────────────────────────────────────────────────────────────────
  return (
    <div className="max-w-350 mx-auto px-4 py-6 space-y-5">
      {/* Header */}
      <div className="flex items-center justify-between gap-3">
        <div className="flex items-center gap-2.5">
          <MapPin className="h-6 w-6 text-primary" aria-hidden />
          <h1 className="text-2xl font-bold text-foreground">
            {t('locations.title', 'Ubicacions')}
          </h1>
        </div>
        <Button onClick={handleOpenCreate} disabled={!activeSite}>
          <Plus className="h-4 w-4 mr-1.5" />
          {t('locations.new_location', 'Nova ubicació')}
        </Button>
      </div>

      {activeSite ? (
        <>
      {/* Selected path */}
      {selectedAncestors.length > 0 && (
        <nav aria-label="breadcrumb" className="flex items-center gap-1 text-sm text-muted-foreground flex-wrap">
          <span className="flex items-center gap-1">
            <Home className="h-3.5 w-3.5" aria-hidden />
            <span>{t('locations.breadcrumb_root', 'Totes les ubicacions')}</span>
          </span>
          {selectedAncestors.map((ancestor) => (
            <span key={ancestor.id} className="flex items-center gap-1">
              <ChevronRight className="h-3.5 w-3.5" aria-hidden />
              <button
                type="button"
                className="hover:text-foreground transition-colors"
                onClick={() => ancestor.id && setSelectedLocationId(ancestor.id)}
              >
                {ancestor.name ?? t('locations.common.not_available', 'N/D')}
              </button>
            </span>
          ))}
        </nav>
      )}

      <div className="grid grid-cols-1 xl:grid-cols-[320px_minmax(0,1fr)_360px] gap-4 items-start">
        {/* Tree panel */}
        <aside className="rounded-2xl border bg-card p-3 space-y-3">
          <div className="space-y-1">
            <h2 className="text-sm font-semibold text-foreground">
              {t('locations.tree.title', "Arbre d'ubicacions")}
            </h2>
            <p className="text-xs text-muted-foreground">
              {t('locations.tree.subtitle', 'Navega la jerarquia i selecciona una zona per veure el detall.')}
            </p>
          </div>

          <div className="relative">
            <Search className="absolute left-2.5 top-2.5 h-4 w-4 text-muted-foreground" aria-hidden />
            <Input
              value={searchTerm}
              onChange={(event) => setSearchTerm(event.target.value)}
              placeholder={t('locations.tree.search_placeholder', 'Cercar zona, sala o planta...')}
              className="pl-8"
            />
          </div>

          {rootLocations.length === 0 ? (
            <div className="rounded-xl border border-dashed p-5 text-center text-sm text-muted-foreground">
              {t('locations.tree.empty', 'No hi ha ubicacions creades encara.')}
            </div>
          ) : visibleNodeIds && visibleNodeIds.size === 0 ? (
            <div className="rounded-xl border border-dashed p-5 text-center text-sm text-muted-foreground">
              {t('locations.tree.no_results', 'No s\'han trobat ubicacions amb aquest filtre.')}
            </div>
          ) : (
            <ul className="space-y-1">
              {rootLocations.map((location) => renderTreeNode(location, 0))}
            </ul>
          )}
        </aside>

        {/* Floorplan / GPS panel */}
        <section className="rounded-2xl border bg-card p-3 space-y-3">
          <div className="flex items-start justify-between gap-3">
            <div className="space-y-1">
              <h2 className="text-sm font-semibold text-foreground">
                {t('locations.map.title', 'Ubicacions')}
              </h2>
              <p className="text-xs text-muted-foreground">
                {t('locations.map.subtitle', 'Gestiona plànols del local i ubicacions amb coordenades GPS.')}
              </p>
            </div>
            <Badge variant="outline" className="text-[11px]">
              {t('locations.map.badge_beta', 'Beta')}
            </Badge>
          </div>

          {/* Tab Selector */}
          <div className="flex gap-2 border-b">
            <button
              type="button"
              onClick={() => setMapViewTab('floorplans')}
              className={`px-3 py-2 text-xs font-medium border-b-2 transition-colors ${
                mapViewTab === 'floorplans'
                  ? 'border-primary text-primary'
                  : 'border-transparent text-muted-foreground hover:text-foreground'
              }`}
            >
              {t('locations.map.floorplans_tab', `Plànols del local`).trim()}
            </button>
            <button
              type="button"
              onClick={() => setMapViewTab('map')}
              className={`px-3 py-2 text-xs font-medium border-b-2 transition-colors ${
                mapViewTab === 'map'
                  ? 'border-primary text-primary'
                  : 'border-transparent text-muted-foreground hover:text-foreground'
              }`}
            >
              {t('locations.map.locations_tab', 'Mapa d\'ubicacions')}
            </button>
          </div>

          {/* Floor Plans Tab */}
          {mapViewTab === 'floorplans' && (
            <div className="space-y-2">
              <div className="space-y-1.5">
                <p className="text-[11px] text-muted-foreground">
                  {t('locations.map.plans_title', 'Plànols')}
                </p>
                <div className="flex flex-wrap gap-1.5">
                  {floorplanLevelOptions.map((level) => (
                    <button
                      key={level.id}
                      type="button"
                      onClick={() => setSelectedMapLevel(level.id)}
                      onDragOver={(event) => handlePlanDragOver(event, level.id)}
                      onDragLeave={() => setHoverPlanId((prev) => (prev === level.id ? null : prev))}
                      onDrop={(event) => handlePlanDrop(event, level.id)}
                      className={`rounded-md border px-2 py-1 text-xs font-medium transition-all duration-150 ${
                        selectedMapLevel === level.id
                          ? 'border-primary bg-primary/10 text-primary'
                          : 'border-border text-muted-foreground hover:text-foreground hover:bg-accent/40'
                      } ${
                        draggingLocationId && hoverPlanId === level.id
                          ? 'ring-4 ring-primary ring-offset-2 bg-primary/20 border-primary shadow-lg scale-105'
                          : draggingLocationId
                            ? 'ring-2 ring-primary/50 border-primary/60 bg-accent/20'
                            : ''
                      }`}
                      title={t('locations.map.select_plan', 'Seleccionar plànol')}
                    >
                      {level.label} ({level.count})
                    </button>
                  ))}
                </div>
              </div>

              {canManageFloorplan && (
                <Button
                  type="button"
                  size="sm"
                  variant="outline"
                  onClick={() => setCreatePlanModalOpen(true)}
                  className="h-8"
                >
                  <Plus className="h-3.5 w-3.5 mr-1.5" />
                  {t('locations.map.create_plan_action', 'Crear plànol')}
                </Button>
              )}

              <p className="text-[11px] text-muted-foreground">
                {canManageFloorplan
                  ? t(
                      'locations.map.edit_hint_with_canvas',
                      'Els noms es mostren sempre. Arrossega la zona per moure-la i fes servir les cantonades per redimensionar-la. Pots arrossegar zones des de l\'arbre al canvas per assignar-les.',
                    )
                  : t(
                      'locations.map.readonly_hint',
                      'Els noms de les zones són visibles al plànol. Només usuaris amb permís de gestió poden editar la mida i posició.',
                    )}
              </p>

              <div
                ref={floorplanCanvasRef}
                onDragOver={handleFloorplanCanvasDragOver}
                onDrop={handleFloorplanCanvasDrop}
                className={`relative h-105 overflow-hidden rounded-xl border bg-muted/20 transition-all ${
                  floorplanEditState ? 'cursor-grabbing' : 'cursor-default'
                } ${draggingLocationId ? 'ring-2 ring-primary/40' : ''}`}
              >
                <div
                  className="absolute inset-0"
                  style={{
                    backgroundImage:
                      'linear-gradient(to right, rgba(100,116,139,0.14) 1px, transparent 1px), linear-gradient(to bottom, rgba(100,116,139,0.14) 1px, transparent 1px)',
                    backgroundSize: '28px 28px',
                  }}
                />

                {visibleFloorplanLocations.length === 0 ? (
                  <div className="pointer-events-none absolute inset-0 z-10 flex flex-col items-center justify-center px-8 text-center text-sm text-muted-foreground">
                    <p>
                      {floorplanLevelOptions.length > 1
                        ? t('locations.map.internal_empty_level', 'Encara no hi ha zones en aquest plànol.')
                        : t('locations.map.internal_empty', 'Encara no hi ha zones al plànol.')}
                    </p>
                    <p className="mt-1 text-xs">
                      {t('locations.map.internal_empty_drop_hint', 'Arrossega una ubicació des de l\'arbre per col·locar-la aquí.')}
                    </p>
                  </div>
                ) : (
                  visibleFloorplanLocations.map((location) => {
                    if (!location.id) return null
                    const rect = floorplanRects.get(location.id)
                    if (!rect) return null

                    const isSelected = selectedLocationId === location.id
                    const isInSelectedScope = selectedScopeSet.has(location.id)
                    const isWritable = canEditFloorplan(location)

                    return (
                      <div
                        key={location.id}
                        className={`group absolute rounded-md border transition-all ${
                          isSelected
                            ? 'border-primary bg-primary/10 shadow-md shadow-primary/20'
                            : isInSelectedScope
                              ? 'border-emerald-600/80 bg-emerald-500/10'
                              : 'border-slate-400/90 bg-slate-500/5'
                        }`}
                        style={{
                          left: `${rect.x}%`,
                          top: `${rect.y}%`,
                          width: `${rect.width}%`,
                          height: `${rect.height}%`,
                        }}
                        onClick={() => handleSelectLocation(location)}
                        onPointerDown={(event) => {
                          if (!isWritable) return
                          handleStartFloorplanEdit(event, location, 'move')
                        }}
                        title={t('locations.map.marker', '{{name}}', {
                          name: location.name ?? t('locations.common.not_available', 'N/D'),
                        })}
                        role="button"
                        tabIndex={0}
                        onKeyDown={(event) => {
                          if (event.key === 'Enter' || event.key === ' ') {
                            event.preventDefault()
                            handleSelectLocation(location)
                          }
                        }}
                        aria-label={t('locations.map.select_location', 'Seleccionar ubicació al mapa')}
                      >
                        <div className="pointer-events-none absolute inset-0 flex items-center justify-center px-1.5 text-center">
                          <span className="max-w-full truncate text-[11px] font-semibold text-foreground">
                            {location.name ?? t('locations.common.not_available', 'N/D')}
                          </span>
                        </div>

                        {isWritable && (
                          <>
                            {(['nw', 'ne', 'sw', 'se'] as const).map((corner) => (
                              <button
                                key={corner}
                                type="button"
                                onPointerDown={(event) => handleStartFloorplanEdit(event, location, 'resize', corner)}
                                className={`absolute z-20 h-2.5 w-2.5 rounded-full border border-primary/70 bg-background ${getCornerHandleClass(corner)}`}
                                title={t('locations.map.resize_zone', 'Redimensionar zona')}
                                aria-label={t('locations.map.resize_zone', 'Redimensionar zona')}
                              />
                            ))}
                          </>
                        )}
                      </div>
                    )
                  })
                )}
              </div>
            </div>
          )}

          {/* Map Tab */}
          {mapViewTab === 'map' && (
            <div className="space-y-2">
              <h3 className="text-xs font-semibold uppercase tracking-wide text-foreground">
                {t('locations.map.gps_title', 'Ubicacions amb GPS')}
              </h3>

              <p className="text-[11px] text-muted-foreground">
                {t(
                  'locations.map.external_map_hint',
                  'Mapa OSM amb markers de sites i ubicacions amb coordenades disponibles.',
                )}
              </p>

              {externalMapCenter ? (
                <div className="overflow-hidden rounded-xl border">
                  {mapsJsApiKey ? (
                    <APIProvider apiKey={mapsJsApiKey} libraries={[]}>
                      <GoogleMap
                        key={externalMapKey}
                        mapId={mapsJsMapId}
                        center={{ lat: externalMapCenter[0], lng: externalMapCenter[1] }}
                        zoom={13}
                        className="h-72 w-full"
                      >
                        {externalMapMarkers.map((marker) => (
                          <Marker
                            key={marker.id}
                            position={{ lat: marker.lat, lng: marker.lng }}
                            onClick={() => {
                              if (marker.kind !== 'location' || !marker.locationId) return
                              const location = allLocations.find((item) => item.id === marker.locationId)
                              if (location) handleSelectLocation(location)
                            }}
                          />
                        ))}
                      </GoogleMap>
                    </APIProvider>
                  ) : (
                    <div className="flex h-72 items-center justify-center text-sm text-muted-foreground bg-muted/20">
                      {t('locations.map.visual_unavailable', 'Mapa visual no disponible')}
                    </div>
                  )}
                </div>
              ) : (
                <div className="rounded-xl border border-dashed px-3 py-5 text-sm text-muted-foreground text-center">
                  {t(
                    'locations.map.external_map_empty',
                    'No hi ha coordenades disponibles per mostrar al mapa de sites i ubicacions.',
                  )}
                </div>
              )}

              {externalGpsLocations.length === 0 ? (
                <div className="rounded-xl border border-dashed px-3 py-5 text-sm text-muted-foreground text-center">
                  {t('locations.map.external_empty', 'No hi ha ubicacions amb coordenades GPS.')}
                </div>
              ) : (
                <ul className="space-y-1.5">
                  {externalGpsLocations.map((location) => {
                    if (!location.id) return null
                    const gps = gpsPointsByLocationId.get(location.id)
                    if (!gps) return null

                    const isSelected = selectedLocationId === location.id
                    const googleMapsUrl = buildGoogleMapsUrl(gps)
                    const locationAddress = extractAddressFromGeo(location.geo_coordinates)

                    return (
                      <li key={location.id}>
                        <div
                          className={`rounded-lg border px-3 py-2 transition-colors ${
                            isSelected
                              ? 'border-primary/50 bg-primary/5'
                              : 'hover:bg-accent/40 border-border'
                          }`}
                        >
                          <div className="flex items-start justify-between gap-2">
                            <button
                              type="button"
                              onClick={() => handleSelectLocation(location)}
                              className="min-w-0 flex-1 text-left"
                              title={t('locations.map.select_location', 'Seleccionar ubicació al mapa')}
                            >
                              <p className="text-sm font-medium text-foreground truncate">
                                {location.name ?? t('locations.common.not_available', 'N/D')}
                              </p>
                              <p className="text-[11px] text-muted-foreground mt-0.5">
                                {t('locations.map.gps_coordinates', 'GPS: {{lat}}, {{lng}}', {
                                  lat: gps.lat.toFixed(5),
                                  lng: gps.lng.toFixed(5),
                                })}
                              </p>
                              {locationAddress && (
                                <p className="text-[11px] text-muted-foreground mt-0.5 truncate">
                                  {locationAddress}
                                </p>
                              )}
                            </button>

                            <a
                              href={googleMapsUrl}
                              target="_blank"
                              rel="noopener noreferrer"
                              className="shrink-0 inline-flex h-7 w-7 items-center justify-center rounded-md border bg-background/95 text-muted-foreground hover:text-foreground"
                              title={t('locations.map.open_google_maps', 'Obrir a Google Maps')}
                              aria-label={t('locations.map.open_google_maps', 'Obrir a Google Maps')}
                            >
                              <ExternalLink className="h-3.5 w-3.5" aria-hidden />
                            </a>
                          </div>
                        </div>
                      </li>
                    )
                  })}
                </ul>
              )}
            </div>
          )}

          {locationsWithoutPoint.length > 0 && (
            <div className="rounded-xl border border-dashed px-3 py-2 text-xs text-muted-foreground space-y-1">
              <p>
                {t('locations.map.missing_positions', '{{count}} zones sense posició interna ni GPS', {
                  count: locationsWithoutPoint.length,
                })}
              </p>
              <p>
                {t('locations.map.missing_positions_hint', 'Defineix map_position per plànol intern o geo_coordinates per GPS extern.')}
              </p>
            </div>
          )}
        </section>

        {/* Zone detail panel */}
        <aside className="rounded-2xl border bg-card p-3 space-y-3">
          <div className="space-y-1">
            <h2 className="text-sm font-semibold text-foreground">
              {t('locations.zone_detail.title', 'Fitxa de zona')}
            </h2>
            <p className="text-xs text-muted-foreground">
              {t('locations.zone_detail.subtitle', 'Resum operatiu de la zona seleccionada i subzones.')}
            </p>
          </div>

          {!selectedLocation ? (
            <div className="rounded-xl border border-dashed p-5 text-center text-sm text-muted-foreground">
              {t('locations.zone_detail.empty', 'Selecciona una ubicació de l\'arbre o del mapa per veure el detall.')}
            </div>
          ) : (
            <div className="space-y-3">
              <div className="rounded-xl border p-3 space-y-2">
                <div className="flex items-start justify-between gap-2">
                  <div>
                    <p className="text-base font-semibold text-foreground">
                      {selectedLocation.name ?? t('locations.common.not_available', 'N/D')}
                    </p>
                    <p className="text-xs text-muted-foreground mt-0.5">
                      {t('locations.zone_detail.path_label', 'Ruta')}: {selectedAncestors
                        .map((ancestor) => ancestor.name ?? t('locations.common.not_available', 'N/D'))
                        .join(' / ')}
                    </p>
                  </div>
                  <LocateFixed className="h-4 w-4 text-muted-foreground" aria-hidden />
                </div>

                <div className="flex flex-wrap items-center gap-1.5">
                  <Badge variant="outline" className="text-[11px]">
                    {t(`locations.type.${selectedLocation.type ?? 'other'}`, selectedLocation.type ?? 'other')}
                  </Badge>
                  <Badge variant="outline" className="text-[11px]">
                    {t(`locations.status.${selectedLocation.status ?? 'inactive'}`, selectedLocation.status ?? 'inactive')}
                  </Badge>
                </div>
              </div>

              <div className="rounded-xl border p-3 space-y-2.5">
                <p className="text-xs font-semibold text-foreground uppercase tracking-wide">
                  {t('locations.zone_detail.capacity_section', 'Ocupació')}
                </p>

                <div className="flex items-center justify-between text-sm">
                  <span className="text-muted-foreground flex items-center gap-1.5">
                    <Users className="h-3.5 w-3.5" aria-hidden />
                    {t('locations.zone_detail.capacity_max', 'Aforament màxim')}
                  </span>
                  <span className="font-medium text-foreground">
                    {maximumCapacity ?? t('locations.common.not_available', 'N/D')}
                  </span>
                </div>

                <div className="flex items-center justify-between text-sm">
                  <span className="text-muted-foreground flex items-center gap-1.5">
                    <Users className="h-3.5 w-3.5" aria-hidden />
                    {t('locations.zone_detail.occupancy_estimated', 'Ocupació actual estimada')}
                  </span>
                  <span className="font-medium text-foreground">{estimatedOccupancy}</span>
                </div>

                <div className="flex items-center justify-between text-sm">
                  <span className="text-muted-foreground flex items-center gap-1.5">
                    <Gauge className="h-3.5 w-3.5" aria-hidden />
                    {t('locations.zone_detail.usage_percent', "Percentatge d'ús")}
                  </span>
                  <span
                    className={`font-medium ${
                      usagePercent === null
                        ? 'text-muted-foreground'
                        : usagePercent > 100
                          ? 'text-amber-600'
                          : 'text-foreground'
                    }`}
                  >
                    {usagePercent === null
                      ? t('locations.zone_detail.usage_no_capacity', 'N/D')
                      : `${usagePercent}%`}
                  </span>
                </div>

                <p className="text-[11px] text-muted-foreground">
                  {t(
                    'locations.zone_detail.occupancy_note',
                    'Estimació basada en work logs oberts visibles per permisos de l\'usuari.',
                  )}
                </p>
              </div>

              <LocationAttendanceEmployeesPanel
                location={selectedLocation}
                canManage={
                  canManageAttendanceAssignments &&
                  !!activeSite &&
                  selectedLocation.site_id === activeSite.id
                }
              />

              <LocationLinkedStationsPanel location={selectedLocation} />

              <div className="rounded-xl border p-3 space-y-2.5">
                <p className="text-xs font-semibold text-foreground uppercase tracking-wide flex items-center gap-1.5">
                  <Wrench className="h-3.5 w-3.5" aria-hidden />
                  {t('locations.zone_detail.assets_section', "Estat d'actius")}
                </p>

                <div className="grid grid-cols-2 gap-2 text-sm">
                  <div className="rounded-lg bg-muted/40 px-2 py-1.5">
                    <p className="text-[11px] text-muted-foreground">{t('locations.assets.operational', 'Operatius')}</p>
                    <p className="font-semibold text-foreground">{assetCounts.operational}</p>
                  </div>
                  <div className="rounded-lg bg-muted/40 px-2 py-1.5">
                    <p className="text-[11px] text-muted-foreground">{t('locations.assets.repairing', 'Reparació')}</p>
                    <p className="font-semibold text-foreground">{assetCounts.repairing}</p>
                  </div>
                  <div className="rounded-lg bg-muted/40 px-2 py-1.5">
                    <p className="text-[11px] text-muted-foreground">{t('locations.assets.down', 'Avaria')}</p>
                    <p className="font-semibold text-foreground">{assetCounts.down}</p>
                  </div>
                  <div className="rounded-lg bg-muted/40 px-2 py-1.5">
                    <p className="text-[11px] text-muted-foreground">{t('locations.assets.retired', 'Retirats')}</p>
                    <p className="font-semibold text-foreground">{assetCounts.retired}</p>
                  </div>
                </div>

                <div className="flex items-center justify-between text-sm pt-1 border-t">
                  <span className="text-muted-foreground">
                    {t('locations.zone_detail.active_projects', 'Projectes actius a la zona')}
                  </span>
                  <span className="font-medium text-foreground">{activeProjectsCount}</span>
                </div>
              </div>

              <div className="rounded-xl border p-3 space-y-2">
                <p className="text-xs font-semibold text-foreground uppercase tracking-wide">
                  {t('locations.zone_detail.quick_actions', 'Accions ràpides')}
                </p>

                <div className="flex flex-wrap gap-2">
                  <Button
                    size="sm"
                    variant="outline"
                    onClick={() => handleEdit(selectedLocation)}
                    disabled={!activeSite || selectedLocation.site_id !== activeSite.id}
                  >
                    {t('locations.actions.edit', 'Editar')}
                  </Button>
                  <Button
                    size="sm"
                    variant="outline"
                    onClick={() => handleAddChild(selectedLocation)}
                    disabled={!activeSite || selectedLocation.site_id !== activeSite.id}
                  >
                    {t('locations.actions.add_child', 'Afegir sububicació')}
                  </Button>
                  <Button
                    size="sm"
                    variant="outline"
                    onClick={() => handleToggleStatus(selectedLocation)}
                    disabled={!activeSite || selectedLocation.site_id !== activeSite.id}
                  >
                    {selectedLocation.status === 'active'
                      ? t('locations.actions.set_inactive', 'Marcar com a inactiu')
                      : t('locations.actions.set_active', 'Marcar com a actiu')}
                  </Button>
                </div>
              </div>

              {operationalLoading && (
                <p className="text-xs text-muted-foreground">
                  {t('locations.zone_detail.loading_metrics', 'Carregant mètriques operatives...')}
                </p>
              )}

              {activeRole !== 'owner' && activeRole !== 'manager' && (
                <p className="text-xs text-muted-foreground">
                  {t('locations.zone_detail.permissions_hint', 'Algunes mètriques poden ser parcials segons el teu rol.')}
                </p>
              )}
            </div>
          )}
        </aside>
      </div>

      {/* Legacy empty safeguard for no locations at all */}
      {allLocations.length === 0 && (
        <div className="text-center py-8 text-muted-foreground">
          <MapPin className="h-8 w-8 mx-auto mb-2 opacity-25" />
          <p className="text-sm">{t('locations.empty', 'No hi ha ubicacions en aquest nivell')}</p>
        </div>
      )}
        </>
      ) : (
        <div className="rounded-2xl border border-dashed bg-card px-6 py-10">
          <div className="text-center">
            <p className="text-sm font-medium text-foreground">
              {t('locations.info.select_site_view', 'Selecciona un local per visualitzar l\'arbre, el mapa i la fitxa de zona.')}
            </p>
            <p className="text-xs text-muted-foreground mt-1.5">
              {t('locations.info.select_site_view_hint', 'En mode "Tots els locals" no es carreguen ubicacions per evitar barrejar estructures de sites diferents.')}
            </p>
            <p className="text-xs text-muted-foreground mt-4">
              {t('locations.info.select_site_action', 'Tria un dels locals disponibles:')}
            </p>
          </div>

          <div className="mt-4 grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3 max-w-3xl mx-auto">
            {sites.map((site) => (
              <button
                key={site.id}
                type="button"
                onClick={() => setSelectedSiteId(site.id)}
                className="flex items-center gap-3 p-4 rounded-lg border border-border hover:border-primary hover:bg-accent transition-colors text-left"
              >
                <MapPin className="h-5 w-5 text-muted-foreground shrink-0" aria-hidden />
                <span className="font-medium text-foreground truncate">{site.name}</span>
              </button>
            ))}
          </div>
        </div>
      )}

      <Dialog
        open={!!pendingAssignment}
        onOpenChange={(open) => {
          if (!open) {
            setPendingAssignment(null)
            setHoverPlanId(null)
          }
        }}
      >
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{t('locations.map.assign_modal_title', 'Confirmar assignació al plànol')}</DialogTitle>
            <DialogDescription>
              {t(
                'locations.map.assign_modal_description',
                'Vols assignar la zona {{zone}} al plànol {{plan}}?',
                {
                  zone: pendingAssignmentLocation?.name ?? t('locations.common.not_available', 'N/D'),
                  plan: pendingAssignmentPlanLabel,
                },
              )}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button
              variant="outline"
              onClick={() => {
                setPendingAssignment(null)
                setHoverPlanId(null)
              }}
            >
              {t('locations.form.cancel', 'Cancel·lar')}
            </Button>
            <Button onClick={handleConfirmAssignToPlan} disabled={updateMutation.isPending}>
              {t('locations.map.assign_modal_confirm', 'Assignar al plànol')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Create / Edit modal */}
      <LocationForm
        open={formOpen}
        onClose={() => setFormOpen(false)}
        editLocation={editTarget}
        defaultParentId={formDefaultParentId}
        allLocations={allLocations}
      />

      {/* Create Floorplan modal */}
      <CreateFloorplanModal
        open={createPlanModalOpen}
        onOpenChange={setCreatePlanModalOpen}
        value={newFloorplanDraft}
        onChange={setNewFloorplanDraft}
        onSubmit={handleCreateFloorplan}
        isLoading={updateMutation.isPending}
      />
    </div>
  )
}
