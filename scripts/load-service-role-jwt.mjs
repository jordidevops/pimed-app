import { execSync } from 'node:child_process'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..')

export function looksLikeJwt(value) {
  return typeof value === 'string' && value.split('.').length === 3
}

/**
 * JWT `service_role` per a Storage/REST. El JWT secret (hex) NO serveix:
 * Storage respon 403 Invalid Compact JWS.
 * Ordre: SUPABASE_SERVICE_ROLE_KEY (si és JWT) → `supabase status -o json`.
 */
export function loadServiceRoleJwt() {
  const fromEnv = process.env.SUPABASE_SERVICE_ROLE_KEY ?? ''
  if (looksLikeJwt(fromEnv)) return fromEnv
  try {
    const raw = execSync('supabase status -o json', {
      cwd: ROOT,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    })
    const status = JSON.parse(raw)
    const fromStatus = status.SERVICE_ROLE_KEY ?? status.SECRET_KEY ?? ''
    if (looksLikeJwt(fromStatus)) return fromStatus
  } catch {
    // CLI local no disponible
  }
  return ''
}
