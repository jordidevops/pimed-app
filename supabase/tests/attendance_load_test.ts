/**
 * Proves de càrrega — control horari (Fase 0 v3)
 *
 * Simula pics de fitxatges i mesura latència RPC + temps de buidatge de cua.
 *
 * Ús local:
 *   npx tsx supabase/tests/attendance_load_test.ts
 *   npx tsx supabase/tests/attendance_load_test.ts --users 500 --concurrency 50
 *   npx tsx supabase/tests/attendance_load_test.ts --users 1000 --skip-drain
 *
 * Variables: SUPABASE_URL (o NEXT_PUBLIC_SUPABASE_URL), SUPABASE_SERVICE_ROLE_KEY
 */

import { createClient, type SupabaseClient } from '@supabase/supabase-js'
import { randomUUID } from 'node:crypto'

const SUPABASE_URL =
  process.env.SUPABASE_URL ??
  process.env.NEXT_PUBLIC_SUPABASE_URL ??
  'http://127.0.0.1:54321'

const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY ?? process.env.SERVICE_ROLE_KEY

const ACME_TENANT = '10000000-0000-0000-0000-000000000001'

const SLO = {
  record_punch_p95_ms: 400,
  recompute_drain_p95_ms: 30_000,
  queue_stale_sec: 300,
} as const

interface Args {
  users: number
  concurrency: number
  punchType: 'in' | 'out'
  skipDrain: boolean
  tenantId: string
}

interface QueueHealth {
  queue_length?: number
  oldest_msg_age_sec?: number
  dlq_count?: number
  catch_up_mode?: boolean
  recommended_max_batches?: number
}

function parseArgs(): Args {
  const argv = process.argv.slice(2)
  const get = (flag: string, fallback: string) => {
    const i = argv.indexOf(flag)
    return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback
  }
  return {
    users: Math.max(1, parseInt(get('--users', '100'), 10)),
    concurrency: Math.max(1, parseInt(get('--concurrency', '25'), 10)),
    punchType: get('--punch-type', 'in') === 'out' ? 'out' : 'in',
    skipDrain: argv.includes('--skip-drain'),
    tenantId: get('--tenant', ACME_TENANT),
  }
}

function percentile(sorted: number[], p: number): number {
  if (sorted.length === 0) return 0
  const idx = Math.ceil((p / 100) * sorted.length) - 1
  return sorted[Math.max(0, Math.min(idx, sorted.length - 1))]
}

async function fetchEmployeeIds(db: SupabaseClient, tenantId: string, limit: number): Promise<string[]> {
  const { data, error } = await db
    .from('employees')
    .select('id')
    .eq('tenant_id', tenantId)
    .eq('status', 'active')
    .not('site_id', 'is', null)
    .limit(limit)

  if (error) throw new Error(`employees: ${error.message}`)
  const ids = (data ?? []).map((r) => r.id as string).filter(Boolean)
  if (ids.length === 0) {
    throw new Error('Cap empleat actiu amb site_id. Executa seed.sql + attendance_demo.sql.')
  }
  return ids
}

async function getQueueHealth(db: SupabaseClient): Promise<QueueHealth | null> {
  const { data, error } = await db.rpc('get_attendance_queue_health')
  if (error) {
    console.warn(`⚠️  get_attendance_queue_health: ${error.message}`)
    return null
  }
  return data as QueueHealth
}

async function recordPunch(
  db: SupabaseClient,
  employeeId: string,
  punchType: 'in' | 'out',
): Promise<{ ok: boolean; ms: number; error?: string }> {
  const started = performance.now()
  const { error } = await db.rpc('record_time_punch', {
    p_employee_id: employeeId,
    p_client_op_id: randomUUID(),
    p_punch_type: punchType,
    p_occurred_at: new Date().toISOString(),
    p_source: 'load_test',
  })
  const ms = Math.round(performance.now() - started)
  if (error) return { ok: false, ms, error: error.message }
  return { ok: true, ms }
}

async function runPunchBurst(
  db: SupabaseClient,
  employeeIds: string[],
  total: number,
  concurrency: number,
  punchType: 'in' | 'out',
) {
  const latencies: number[] = []
  let errors = 0
  let completed = 0

  const workers = Array.from({ length: concurrency }, async () => {
    while (true) {
      const i = completed++
      if (i >= total) break
      const employeeId = employeeIds[i % employeeIds.length]
      const result = await recordPunch(db, employeeId, punchType)
      latencies.push(result.ms)
      if (!result.ok) {
        errors++
        if (errors <= 5) {
          console.error(`  punch error #${errors}: ${result.error}`)
        }
      }
    }
  })

  await Promise.all(workers)
  latencies.sort((a, b) => a - b)
  return { latencies, errors, total }
}

async function drainQueue(functionsUrl: string, serviceKey: string, maxRounds = 30) {
  const drainLatencies: number[] = []
  let totalSucceeded = 0

  for (let round = 0; round < maxRounds; round++) {
    const started = performance.now()
    const res = await fetch(`${functionsUrl}/process-attendance-queue`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${serviceKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ catch_up: true, max_batches: 10, batch_size: 50 }),
    })
    const body = await res.json().catch(() => ({}))
    const ms = Math.round(performance.now() - started)
    drainLatencies.push(ms)

    if (!res.ok) {
      throw new Error(`drain HTTP ${res.status}: ${JSON.stringify(body)}`)
    }

    const succeeded = Number(body.succeeded ?? 0)
    totalSucceeded += succeeded
    const queueLen = body.queue_health?.queue_length ?? '?'

    console.log(
      `  drain round ${round + 1}: ${succeeded} ok, ${ms}ms, queue_length=${queueLen}`,
    )

    if (succeeded === 0 && (queueLen === 0 || queueLen === '?')) break
    if (body.batches_run === 1 && body.total === 0) break
  }

  drainLatencies.sort((a, b) => a - b)
  return { drainLatencies, totalSucceeded }
}

async function main() {
  if (!SERVICE_KEY) {
    console.error('❌ Cal SUPABASE_SERVICE_ROLE_KEY (supabase status --output env)')
    process.exit(1)
  }

  const args = parseArgs()
  const db = createClient(SUPABASE_URL, SERVICE_KEY, { db: { schema: 'api' } })
  const functionsUrl = SUPABASE_URL.replace(/\/$/, '') + '/functions/v1'

  console.log('═'.repeat(60))
  console.log('Attendance load test — Control Horari Fase 0')
  console.log(`URL: ${SUPABASE_URL}`)
  console.log(`Punches: ${args.users} (concurrency ${args.concurrency}, type=${args.punchType})`)
  console.log('═'.repeat(60))

  const healthBefore = await getQueueHealth(db)
  if (healthBefore) {
    console.log(
      `Queue abans: length=${healthBefore.queue_length}, oldest_age=${healthBefore.oldest_msg_age_sec}s, dlq=${healthBefore.dlq_count}`,
    )
  }

  const employeeIds = await fetchEmployeeIds(db, args.tenantId, Math.min(args.users, 500))
  console.log(`Empleats disponibles: ${employeeIds.length}`)

  console.log('\n📥 Burst de fitxatges...')
  const burstStart = performance.now()
  const burst = await runPunchBurst(
    db,
    employeeIds,
    args.users,
    args.concurrency,
    args.punchType,
  )
  const burstMs = Math.round(performance.now() - burstStart)

  const p50 = percentile(burst.latencies, 50)
  const p95 = percentile(burst.latencies, 95)
  const p99 = percentile(burst.latencies, 99)

  console.log('\n── Latència record_time_punch ──')
  console.log(`  total:   ${burst.total} (${burst.errors} errors) en ${burstMs}ms`)
  console.log(`  p50:     ${p50}ms`)
  console.log(`  p95:     ${p95}ms  ${p95 <= SLO.record_punch_p95_ms ? '✅' : '❌'} (SLO <${SLO.record_punch_p95_ms}ms)`)
  console.log(`  p99:     ${p99}ms`)
  console.log(`  throughput: ${Math.round((burst.total / burstMs) * 1000)} punches/s`)

  const healthAfterBurst = await getQueueHealth(db)
  if (healthAfterBurst) {
    console.log(
      `\nQueue després burst: length=${healthAfterBurst.queue_length}, catch_up=${healthAfterBurst.catch_up_mode}`,
    )
  }

  if (!args.skipDrain) {
    console.log('\n🔄 Buidant cua (catch-up)...')
    const drainStart = performance.now()
    const drain = await drainQueue(functionsUrl, SERVICE_KEY)
    const drainTotalMs = Math.round(performance.now() - drainStart)
    const drainP95 = percentile(drain.drainLatencies, 95)

    console.log('\n── Drain recompute ──')
    console.log(`  recomputes: ${drain.totalSucceeded}`)
    console.log(`  temps total drain: ${drainTotalMs}ms`)
    console.log(`  p95 per round: ${drainP95}ms`)

    const healthFinal = await getQueueHealth(db)
    if (healthFinal) {
      const stale = healthFinal.oldest_msg_age_sec ?? 0
      const backlog = healthFinal.queue_length ?? 0
      console.log(
        `\nQueue final: length=${backlog}, oldest_age=${stale}s, dlq=${healthFinal.dlq_count}`,
      )
      console.log(
        `  backlog OK: ${backlog < 50 ? '✅' : '⚠️'}  stale OK: ${stale < SLO.queue_stale_sec ? '✅' : '❌'}`,
      )
    }
  }

  console.log('\n' + '═'.repeat(60))
  console.log('Fi. Revisa logs Edge Function i audit_logs (ASYNC_BATCH_PROCESSED).')
}

main().catch((err) => {
  console.error('❌', err)
  process.exit(1)
})
