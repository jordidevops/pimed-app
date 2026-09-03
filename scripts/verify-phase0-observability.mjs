#!/usr/bin/env node
/**
 * Verificació Fase 0 — observabilitat baseline (health + REST + opcional staging/prod)
 *
 * Ús local (només Supabase local):
 *   node scripts/verify-phase0-observability.mjs
 *
 * Ús amb entorns cloud (omplir variables):
 *   STAGING_REF=xxx PROD_REF=yyy \
 *   TENANT_PORTAL_URL_STAGING=https://... \
 *   ADMIN_PORTAL_URL_STAGING=https://... \
 *   node scripts/verify-phase0-observability.mjs
 *
 * Variables opcionals:
 *   SUPABASE_URL          (default http://127.0.0.1:54321)
 *   STAGING_REF / PROD_REF
 *   TENANT_PORTAL_URL_* / ADMIN_PORTAL_URL_*
 *   ANON_KEY              (per REST amb apikey)
 */

const LOCAL_URL = process.env.SUPABASE_URL ?? 'http://127.0.0.1:54321'
const ANON_KEY =
  process.env.SUPABASE_ANON_KEY ??
  process.env.VITE_SUPABASE_PUBLISHABLE_DEFAULT_KEY ??
  'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH'

const STAGING_REF = process.env.STAGING_REF ?? ''
const PROD_REF = process.env.PROD_REF ?? ''

let passed = 0
let failed = 0
let skipped = 0

function ok(msg) {
  console.log(`  ✓  ${msg}`)
  passed++
}
function fail(msg) {
  console.error(`  ✗  ${msg}`)
  failed++
}
function skip(msg) {
  console.log(`  ○  ${msg} (skipped)`)
  skipped++
}
function section(title) {
  console.log(`\n── ${title} ──`)
}

async function checkGet(name, url, { expectStatus = 200, keyword, headers = {}, timeoutMs = 15_000 } = {}) {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), timeoutMs)
  try {
    const res = await fetch(url, { method: 'GET', headers, signal: controller.signal })
    const text = await res.text()
    if (res.status !== expectStatus) {
      fail(`${name}: HTTP ${res.status} (expected ${expectStatus}) — ${text.slice(0, 120)}`)
      return false
    }
    if (keyword && !text.includes(keyword)) {
      fail(`${name}: response missing keyword "${keyword}" — ${text.slice(0, 120)}`)
      return false
    }
    ok(`${name} → ${res.status}${keyword ? `, contains "${keyword}"` : ''}`)
    return true
  } catch (err) {
    fail(`${name}: ${err instanceof Error ? err.message : String(err)}`)
    return false
  } finally {
    clearTimeout(timer)
  }
}

function supabaseBase(ref) {
  return `https://${ref}.supabase.co`
}

async function verifyLocal() {
  section('Local — Supabase dev stack')
  await checkGet('REST /rest/v1/', `${LOCAL_URL}/rest/v1/`, {
    headers: { apikey: ANON_KEY },
  })
  await checkGet('Health live', `${LOCAL_URL}/functions/v1/health?check=live`, {
    keyword: '"status":"ok"',
  })
  await checkGet('Health ready', `${LOCAL_URL}/functions/v1/health?check=ready`, {
    keyword: '"check":"ready"',
  })
}

async function verifyCloud(label, ref, portalUrls = {}) {
  if (!ref) {
    skip(`${label}: ${ref ? ref : 'REF no configurat'}`)
    return
  }
  section(`${label} (${ref})`)
  const base = supabaseBase(ref)
  await checkGet(`${label} REST`, `${base}/rest/v1/`, {
    headers: { apikey: ANON_KEY },
  })
  await checkGet(`${label} health live`, `${base}/functions/v1/health?check=live`, {
    keyword: '"status":"ok"',
  })
  await checkGet(`${label} health ready`, `${base}/functions/v1/health?check=ready`, {
    keyword: '"check":"ready"',
  })

  for (const [kind, url] of Object.entries(portalUrls)) {
    if (!url) {
      skip(`${label} ${kind}: URL no configurada`)
      continue
    }
    await checkGet(`${label} ${kind}`, url, { expectStatus: 200 })
  }
}

async function main() {
  console.log('\n🔷  Fase 0 — Verificació observabilitat\n')

  await verifyLocal()

  await verifyCloud('Staging', STAGING_REF, {
    'tenant portal': process.env.TENANT_PORTAL_URL_STAGING,
    'admin portal': process.env.ADMIN_PORTAL_URL_STAGING,
  })

  await verifyCloud('Producció', PROD_REF, {
    'tenant portal': process.env.TENANT_PORTAL_URL_PROD,
    'admin portal': process.env.ADMIN_PORTAL_URL_PROD,
  })

  console.log(`\n── Resultat: ${passed} OK, ${failed} FAIL, ${skipped} SKIP ──\n`)

  if (failed > 0) {
    console.log('Revisa docs/runbooks/fase-0-manual-setup.md per configurar UptimeRobot/Sentry.\n')
    process.exit(1)
  }

  if (!STAGING_REF && !PROD_REF) {
    console.log('Consell: defineix STAGING_REF/PROD_REF per verificar entorns cloud.\n')
  }
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
