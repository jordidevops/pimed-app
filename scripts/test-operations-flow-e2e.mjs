#!/usr/bin/env node
/**
 * E2E — flux tenant_operation_logs + RPCs UI (Operacions)
 *
 * Simula una fallada d'email via log_tenant_operation i verifica:
 *   1. Inserció (service_role)
 *   2. get_unresolved_operation_count (owner/manager)
 *   3. get_tenant_operation_logs (filtre email + failed)
 *   4. Denegació per a member (dave)
 *   5. mark_operation_log_resolved → count disminueix
 *
 * Ús:
 *   cd scripts
 *   SUPABASE_URL=http://127.0.0.1:54321 \
 *   SUPABASE_SERVICE_ROLE_KEY=<secret> \
 *   node test-operations-flow-e2e.mjs
 */

import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { execSync } from 'node:child_process'

const SUPABASE_URL = process.env.SUPABASE_URL ?? 'http://127.0.0.1:54321'
let SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY ?? ''
const ANON_KEY =
  process.env.SUPABASE_ANON_KEY ??
  process.env.VITE_SUPABASE_PUBLISHABLE_DEFAULT_KEY ??
  'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH'

function loadLocalServiceKey() {
  if (SERVICE_KEY) return
  try {
    const root = join(dirname(fileURLToPath(import.meta.url)), '..')
    const raw = execSync('supabase status -o json', {
      cwd: root,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    })
    const status = JSON.parse(raw)
    SERVICE_KEY = status.SERVICE_ROLE_KEY ?? status.SECRET_KEY ?? ''
  } catch {
    // ignore — validated below
  }
}

const ACME_TENANT_ID = '10000000-0000-0000-0000-000000000001'
const ALICE = { email: 'alice@acme-corp.com', password: process.env.E2E_PASSWORD ?? 'Test1234!' }
const DAVE = { email: 'dave@acme-corp.com', password: process.env.E2E_PASSWORD ?? 'Test1234!' }

const CORRELATION_ID = `e2e-ops-${Date.now()}`
const TEST_TITLE = 'E2E: Email no enviat (simulació Resend)'

let passed = 0
let failed = 0
let logId = null

function ok(msg) {
  console.log(`  ✓  ${msg}`)
  passed++
}
function fail(msg) {
  console.error(`  ✗  ${msg}`)
  failed++
}
function assert(cond, msg) {
  if (cond) ok(msg)
  else fail(msg)
}
function section(t) {
  console.log(`\n── ${t} ──`)
}

async function rpc(token, fn, body, { expectError = false } = {}) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: {
      apikey: ANON_KEY,
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
  })
  const text = await res.text()
  let data
  try {
    data = text ? JSON.parse(text) : null
  } catch {
    data = text
  }
  if (!expectError && !res.ok) {
    throw new Error(`RPC ${fn}: ${res.status} ${text.slice(0, 400)}`)
  }
  return { status: res.status, data, text }
}

async function signIn(email, password) {
  const res = await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=password`, {
    method: 'POST',
    headers: {
      apikey: ANON_KEY,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ email, password }),
  })
  const json = await res.json()
  if (!res.ok) throw new Error(`Auth ${email}: ${json.error_description ?? json.msg ?? res.status}`)
  return json.access_token
}

async function seedFailedEmailLog() {
  const { data } = await rpc(SERVICE_KEY, 'log_tenant_operation', {
    p_tenant_id: ACME_TENANT_ID,
    p_integration_type: 'email',
    p_operation_code: 'send_transactional_email',
    p_status: 'failed',
    p_title: TEST_TITLE,
    p_message: 'Invalid API key (E2E simulation)',
    p_error_code: 'provider_error',
    p_error_message: 'Resend API returned 401',
    p_correlation_id: CORRELATION_ID,
    p_external_service: 'resend',
    p_duration_ms: 1200,
    p_duration_threshold_ms: 3000,
    p_attempt_count: 1,
    p_max_attempts: 3,
    p_is_retryable: true,
    p_payload_summary: { subject: 'E2E test', e2e: true },
  })
  logId = data
  assert(typeof logId === 'string' && logId.length > 10, `log_tenant_operation retorna uuid (${logId})`)
}

async function cleanup() {
  if (!logId) return
  await fetch(
    `${SUPABASE_URL}/rest/v1/tenant_operation_logs?id=eq.${logId}`,
    {
      method: 'DELETE',
      headers: {
        apikey: SERVICE_KEY,
        Authorization: `Bearer ${SERVICE_KEY}`,
        'Accept-Profile': 'api',
      },
    },
  ).catch(() => undefined)
}

async function main() {
  loadLocalServiceKey()
  if (!SERVICE_KEY) {
    console.error('❌ Cal SUPABASE_SERVICE_ROLE_KEY (supabase status → Secret)')
    process.exit(1)
  }

  console.log('\n🔷  E2E — Flux Operacions (tenant_operation_logs)\n')
  console.log(`   correlation_id: ${CORRELATION_ID}`)

  try {
    section('1. Seed fallada email (service_role)')
    await seedFailedEmailLog()

    section('2. Owner (alice) — badge count')
    const aliceToken = await signIn(ALICE.email, ALICE.password)
    const { data: countBefore } = await rpc(aliceToken, 'get_unresolved_operation_count', {
      p_tenant_id: ACME_TENANT_ID,
      p_since: null,
    })
    assert(Number(countBefore) >= 1, `get_unresolved_operation_count >= 1 (actual: ${countBefore})`)

    section('3. Owner — llistat amb filtre email/failed')
    const { data: page } = await rpc(aliceToken, 'get_tenant_operation_logs', {
      p_tenant_id: ACME_TENANT_ID,
      p_status: 'failed',
      p_integration_type: 'email',
      p_limit: 50,
      p_offset: 0,
    })
    const items = page?.items ?? []
    const hit = items.find((i) => i.correlation_id === CORRELATION_ID)
    assert(!!hit, 'Llistat conté la incidència E2E per correlation_id')
    assert(hit?.title === TEST_TITLE, 'Títol de la incidència coincideix')

    section('4. Member (dave) — accés denegat (API)')
    const daveToken = await signIn(DAVE.email, DAVE.password)
    const denied = await rpc(
      daveToken,
      'get_unresolved_operation_count',
      { p_tenant_id: ACME_TENANT_ID, p_since: null },
      { expectError: true },
    )
    assert(
      denied.status === 403 ||
        denied.status === 400 ||
        /access denied/i.test(String(denied.text)),
      `Member no pot cridar get_unresolved_operation_count (status=${denied.status}, body=${String(denied.text).slice(0, 120)})`,
    )

    section('5. Owner — marcar com a revisada')
    const { data: resolved } = await rpc(aliceToken, 'mark_operation_log_resolved', {
      p_tenant_id: ACME_TENANT_ID,
      p_log_id: logId,
      p_note: 'E2E test cleanup',
    })
    assert(resolved === true, 'mark_operation_log_resolved retorna true')

    const { data: countAfter } = await rpc(aliceToken, 'get_unresolved_operation_count', {
      p_tenant_id: ACME_TENANT_ID,
      p_since: null,
    })
    assert(Number(countAfter) === Number(countBefore) - 1, `Count disminueix (${countBefore} → ${countAfter})`)

    section('6. Idempotència resolve')
    const { data: resolvedAgain } = await rpc(aliceToken, 'mark_operation_log_resolved', {
      p_tenant_id: ACME_TENANT_ID,
      p_log_id: logId,
      p_note: null,
    })
    assert(resolvedAgain === false, 'Segona resolució retorna false (ja revisada)')
  } finally {
    section('Cleanup')
    await cleanup()
    ok('Registre E2E eliminat (si encara existia)')
  }

  console.log(`\n── Resultat: ${passed} OK, ${failed} FAIL ──\n`)
  process.exit(failed > 0 ? 1 : 0)
}

main().catch((err) => {
  console.error('\n❌ Error fatal:', err.message)
  cleanup().finally(() => process.exit(1))
})
