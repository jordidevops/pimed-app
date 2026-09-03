export type DeviceInfoChannel = 'employee_portal' | 'tenant_portal'
export type DeviceFormFactor = 'mobile' | 'tablet' | 'desktop'

export type DeviceInfoRecord = Record<string, string>

type TranslateFn = (key: string, fallback: string) => string

interface ParsedClient {
  formFactor: DeviceFormFactor
  os: string
  osVersion?: string
  browser: string
  browserVersion?: string
}

interface NavigatorUaData {
  mobile?: boolean
  platform?: string
  brands?: { brand: string; version: string }[]
}

const DEVICE_FIELD_ORDER = [
  'channel',
  'form_factor',
  'os',
  'os_version',
  'browser',
  'browser_version',
  'language',
  'timezone',
  'screen',
  'platform',
  'user_agent',
] as const

function compactRecord(entries: Record<string, string | undefined>): DeviceInfoRecord {
  return Object.fromEntries(
    Object.entries(entries).filter(([, value]) => value != null && String(value).trim() !== ''),
  ) as DeviceInfoRecord
}

function windowsNtLabel(nt: string | undefined): string | undefined {
  if (!nt) return undefined
  const map: Record<string, string> = {
    '10.0': '10/11',
    '6.3': '8.1',
    '6.2': '8',
    '6.1': '7',
  }
  return map[nt] ?? nt
}

/** Anàlisi síncrona de l'entorn client (sense xarxa ni llibreries externes). */
export function parseClientEnvironment(userAgent: string): ParsedClient {
  const uad = (typeof navigator !== 'undefined'
    ? (navigator as Navigator & { userAgentData?: NavigatorUaData }).userAgentData
    : undefined) as NavigatorUaData | undefined

  let formFactor: DeviceFormFactor = 'desktop'
  if (uad?.mobile) {
    formFactor = 'mobile'
  } else if (/iPad|Tablet|PlayBook|Silk/i.test(userAgent)) {
    formFactor = 'tablet'
  } else if (/\bAndroid\b/i.test(userAgent) && !/Mobile/i.test(userAgent)) {
    formFactor = 'tablet'
  } else if (/Mobile|iPhone|iPod|Android.*Mobile|IEMobile|Opera Mini/i.test(userAgent)) {
    formFactor = 'mobile'
  }

  let os = 'Desconegut'
  let osVersion: string | undefined

  if (uad?.platform) {
    os = uad.platform
  } else if (/Windows NT/i.test(userAgent)) {
    os = 'Windows'
    osVersion = windowsNtLabel(userAgent.match(/Windows NT ([\d.]+)/)?.[1])
  } else if (/Mac OS X/i.test(userAgent)) {
    os = 'macOS'
    osVersion = userAgent.match(/Mac OS X ([\d_]+)/)?.[1]?.replace(/_/g, '.')
  } else if (/Android/i.test(userAgent)) {
    os = 'Android'
    osVersion = userAgent.match(/Android ([\d.]+)/)?.[1]
  } else if (/iPhone|iPad|iPod/i.test(userAgent)) {
    os = 'iOS'
    osVersion = userAgent.match(/OS ([\d_]+)/)?.[1]?.replace(/_/g, '.')
  } else if (/Linux/i.test(userAgent)) {
    os = 'Linux'
  }

  let browser = 'Desconegut'
  let browserVersion: string | undefined
  const brand = uad?.brands?.find((b) => !/Not.?A.?Brand/i.test(b.brand))
  if (brand) {
    browser = brand.brand
    browserVersion = brand.version
  } else if (/Edg\//i.test(userAgent)) {
    browser = 'Microsoft Edge'
    browserVersion = userAgent.match(/Edg\/([\d.]+)/)?.[1]
  } else if (/Chrome\//i.test(userAgent) && !/Chromium/i.test(userAgent)) {
    browser = 'Chrome'
    browserVersion = userAgent.match(/Chrome\/([\d.]+)/)?.[1]
  } else if (/Firefox\//i.test(userAgent)) {
    browser = 'Firefox'
    browserVersion = userAgent.match(/Firefox\/([\d.]+)/)?.[1]
  } else if (/Safari\//i.test(userAgent) && !/Chrome/i.test(userAgent)) {
    browser = 'Safari'
    browserVersion = userAgent.match(/Version\/([\d.]+)/)?.[1]
  }

  return { formFactor, os, osVersion, browser, browserVersion }
}

/**
 * Captura metadades del dispositiu/navegador de forma síncrona (microsegons).
 * No bloqueja el fitxatge ni fa crides de xarxa.
 */
export function buildDeviceInfo(channel: DeviceInfoChannel): DeviceInfoRecord {
  if (typeof navigator === 'undefined') {
    return { channel }
  }

  const parsed = parseClientEnvironment(navigator.userAgent)

  return compactRecord({
    channel,
    form_factor: parsed.formFactor,
    os: parsed.os,
    os_version: parsed.osVersion,
    browser: parsed.browser,
    browser_version: parsed.browserVersion,
    language: navigator.language,
    timezone:
      typeof Intl !== 'undefined'
        ? Intl.DateTimeFormat().resolvedOptions().timeZone
        : undefined,
    screen:
      typeof window !== 'undefined'
        ? `${window.screen.width}x${window.screen.height}`
        : undefined,
    platform: navigator.platform || undefined,
  })
}

export function formatPunchSourceLabel(
  source: string | null | undefined,
  t: TranslateFn,
): string | null {
  if (!source) return null
  const key = `punch_details.source.${source}`
  const fallbacks: Record<string, string> = {
    portal: 'Portal empleat',
    mobile: 'App del treballador',
    station: 'Terminal',
    manual_entry: 'Registre manual',
    manager_correction: 'Correcció del gestor',
  }
  return t(key, fallbacks[source] ?? source)
}

export function formatLocationPermissionLabel(
  permission: string | null | undefined,
  t: TranslateFn,
): string | null {
  if (!permission) return null
  const key = `punch_details.location_permission_${permission}`
  const fallbacks: Record<string, string> = {
    granted: 'Permès',
    denied: 'Denegat',
    timeout: 'Temps esgotat',
    error: 'Error',
    notrequired: 'No requerit',
  }
  return t(key, fallbacks[permission] ?? permission)
}

function translateDeviceValue(
  key: string,
  value: string,
  t: TranslateFn,
): string {
  if (key === 'channel') {
    const fallbacks: Record<string, string> = {
      employee_portal: 'Portal empleat',
      tenant_portal: 'Portal de gestió',
    }
    return t(`punch_details.channel.${value}`, fallbacks[value] ?? value)
  }
  if (key === 'form_factor') {
    const factors: Record<string, string> = {
      mobile: 'Mòbil',
      tablet: 'Tauleta',
      desktop: 'Escriptori',
    }
    return t(`punch_details.form_factor.${value}`, factors[value] ?? value)
  }
  return value
}

function deviceFieldLabel(key: string, t: TranslateFn): string {
  const labels: Record<string, string> = {
    channel: 'Canal',
    form_factor: 'Tipus de dispositiu',
    os: 'Sistema operatiu',
    os_version: 'Versió SO',
    browser: 'Navegador',
    browser_version: 'Versió navegador',
    language: 'Idioma',
    timezone: 'Zona horària',
    screen: 'Pantalla',
    platform: 'Plataforma',
    user_agent: 'Agent d\'usuari',
  }
  return t(`punch_details.device_${key}`, labels[key] ?? key)
}

function shouldOmitChannelFromDeviceRows(
  source: string | null | undefined,
  channel: string | undefined,
): boolean {
  return source === 'portal' && channel === 'employee_portal'
}

export function formatDeviceInfoRows(
  deviceInfo: unknown,
  t: TranslateFn,
  options?: { source?: string | null },
): { label: string; value: string }[] {
  if (!deviceInfo || typeof deviceInfo !== 'object') return []

  const raw = deviceInfo as Record<string, unknown>
  const channel = raw.channel != null ? String(raw.channel) : undefined
  const rows: { label: string; value: string }[] = []

  for (const key of DEVICE_FIELD_ORDER) {
    if (key === 'channel' && shouldOmitChannelFromDeviceRows(options?.source, channel)) {
      continue
    }
    const rawValue = raw[key]
    if (rawValue == null || String(rawValue).trim() === '') continue
    const value = String(rawValue)
    rows.push({
      label: deviceFieldLabel(key, t),
      value: translateDeviceValue(key, value, t),
    })
  }

  for (const [key, rawValue] of Object.entries(raw)) {
    if ((DEVICE_FIELD_ORDER as readonly string[]).includes(key)) continue
    if (rawValue == null || String(rawValue).trim() === '') continue
    rows.push({
      label: deviceFieldLabel(key, t),
      value: String(rawValue),
    })
  }

  return rows
}

/** Valors permesos en device_info des del client (portal API). */
export function sanitizeClientDeviceInfo(
  input: unknown,
  fallbackChannel: DeviceInfoChannel,
): DeviceInfoRecord {
  if (!input || typeof input !== 'object') {
    return { channel: fallbackChannel }
  }

  const allowed = new Set<string>([
    ...DEVICE_FIELD_ORDER,
    'channel',
  ])
  const out: DeviceInfoRecord = {}
  for (const [key, value] of Object.entries(input as Record<string, unknown>)) {
    if (!allowed.has(key) || value == null) continue
    const str = String(value).trim().slice(0, 512)
    if (str) out[key] = str
  }
  if (!out.channel) out.channel = fallbackChannel
  return out
}
