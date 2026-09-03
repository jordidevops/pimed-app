export type DeviceInfoChannel = 'employee_portal' | 'tenant_portal'
export type DeviceFormFactor = 'mobile' | 'tablet' | 'desktop'

export type DeviceInfoRecord = Record<string, string>

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
