/**
 * E2E local — MENTION_CREATED (timeline → cua → worker → in-app + digest push)
 *
 * Usage (des del root del repo):
 *   node scripts/mention-notification-e2e.mjs
 */
import { execSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import path from 'node:path'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const SUPABASE_URL = process.env.SUPABASE_URL ?? 'http://127.0.0.1:54321'
const ANON_KEY = process.env.SUPABASE_ANON_KEY
  ?? 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0'
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY
  ?? 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU'

const TENANT_ID = '10000000-0000-0000-0000-000000000001'
const SITE_ID = '30000000-0000-0000-0000-000000000001'
const ALICE_ID = '20000000-0000-0000-0000-000000000002'
const CHARLIE_ID = '20000000-0000-0000-0000-000000000004'
const CHARLIE_EMPLOYEE_ID = '40000000-0000-0000-0000-000000000002'
const PASSWORD = 'Test1234!'

function assert(cond, msg) {
  if (!cond) throw new Error(`FAIL: ${msg}`)
}

function dbQuery(sql) {
  const oneLine = sql.replace(/\s+/g, ' ').trim()
  const out = execSync(`npx supabase db query "${oneLine.replace(/"/g, '\\"')}"`, {
    cwd: ROOT,
    encoding: 'utf8',
    shell: true,
  })
  const match = out.match(/"rows":\s*(\[[\s\S]*?\])\s*,/m)
  if (!match) return []
  return JSON.parse(match[1])
}

async function restRpc(fn, body, accessToken) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: {
      apikey: ANON_KEY,
      Authorization: `Bearer ${accessToken}`,
      'Content-Type': 'application/json',
      'Accept-Profile': 'api',
      'Content-Profile': 'api',
      'x-tenant-id': TENANT_ID,
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
  if (!res.ok) {
    throw new Error(`${fn} → ${res.status}: ${text}`)
  }
  return data
}

async function signIn(email) {
  const res = await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=password`, {
    method: 'POST',
    headers: {
      apikey: ANON_KEY,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ email, password: PASSWORD }),
  })
  const json = await res.json()
  assert(res.ok, `signIn ${email}: ${json.error_description ?? json.msg ?? res.status}`)
  return json.access_token
}

async function processQueue() {
  const res = await fetch(`${SUPABASE_URL}/functions/v1/process-notification-queue`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ batch_size: 20 }),
  })
  const json = await res.json().catch(() => ({}))
  assert(res.ok, `process-notification-queue → ${res.status}: ${JSON.stringify(json)}`)
  return json
}

async function insertMentionComment(token, suffix) {
  const mention = `[[@${CHARLIE_ID}|Charlie Manager]]`
  const content = `Prova E2E menció ${suffix} — hola ${mention}, revisa això.`

  const commentId = await restRpc('insert_entity_comment', {
    p_entity_type: 'employee',
    p_entity_id: CHARLIE_EMPLOYEE_ID,
    p_content: content,
    p_parent_id: null,
    p_is_task: false,
    p_site_id: SITE_ID,
    p_attachments: [],
    p_due_date: null,
    p_is_ai_context_note: false,
  }, token)

  assert(commentId, 'comment id missing')
  return { commentId, content }
}

async function main() {
  console.log('\n🔔 MENTION_CREATED E2E — local\n')

  dbQuery(`DELETE FROM data.notifications WHERE user_id::text = '${CHARLIE_ID}' AND body_i18n->>'ca' LIKE '%Prova E2E menció%'`)
  dbQuery(`DELETE FROM data.notification_digest_buckets WHERE recipient_id::text = '${CHARLIE_ID}'`)
  dbQuery(`DELETE FROM data.entity_comments WHERE content LIKE '%Prova E2E menció%'`)

  const aliceToken = await signIn('alice@acme-corp.com')
  console.log('✓ Alice autenticada')

  const { commentId: comment1 } = await insertMentionComment(aliceToken, '#1')
  console.log(`✓ Comentari 1 creat: ${comment1}`)

  const queue1 = dbQuery(`SELECT count(*)::int AS n FROM pgmq.q_notification_dispatch_queue WHERE message->>'eventType' = 'MENTION_CREATED' AND message->'recipient'->>'userId' = '${CHARLIE_ID}'`)
  assert(queue1[0]?.n >= 1, `cua buida després del comentari 1 (n=${queue1[0]?.n})`)
  console.log(`✓ Cua PGMQ: ${queue1[0].n} missatge(s) MENTION_CREATED`)

  const worker1 = await processQueue()
  console.log(`✓ Worker batch 1: succeeded=${worker1.succeeded}, digest=${JSON.stringify(worker1.digest ?? {})}`)

  const notif1 = dbQuery(`SELECT kind, user_id::text AS user_id, deep_link, body_i18n->>'ca' AS body FROM data.notifications WHERE user_id::text = '${CHARLIE_ID}' AND kind = 'mention_created' ORDER BY created_at DESC LIMIT 1`)
  assert(notif1.length === 1, 'no in-app notification for Charlie')
  const n1 = notif1[0]
  assert(n1.user_id === CHARLIE_ID, 'wrong recipient')
  assert(n1.deep_link?.includes(CHARLIE_EMPLOYEE_ID), `deep_link missing employee id: ${n1.deep_link}`)
  assert(n1.deep_link?.includes(`comment=${comment1}`), `deep_link missing comment id: ${n1.deep_link}`)
  assert(n1.body?.includes('Alice'), `body missing author: ${n1.body}`)
  assert(n1.body?.includes('revisa'), `body missing preview: ${n1.body}`)
  console.log(`✓ In-app: deep_link=${n1.deep_link}`)
  console.log(`  body: ${n1.body}`)

  const deliveries1 = dbQuery(`SELECT channel::text AS channel, status::text AS status, correlation_id FROM data.notification_deliveries WHERE correlation_id = 'mention:${comment1}:${CHARLIE_ID}' ORDER BY channel`)
  const inApp1 = deliveries1.find((d) => d.channel === 'in_app')
  const email1 = deliveries1.find((d) => d.channel === 'email')
  const push1 = deliveries1.find((d) => d.channel === 'push')
  assert(inApp1?.status === 'sent', `in_app not sent: ${JSON.stringify(inApp1)}`)
  assert(!push1, `push should not be sent immediately (digest): ${JSON.stringify(push1)}`)
  console.log(`✓ In-app delivery: ${inApp1.status}`)
  if (email1) console.log(`✓ Email delivery: ${email1.status}`)

  const bucket1 = dbQuery(`SELECT item_count, group_key FROM data.notification_digest_buckets WHERE recipient_id::text = '${CHARLIE_ID}' AND entity_id::text = '${CHARLIE_EMPLOYEE_ID}'`)
  assert(bucket1.length === 1 && bucket1[0].item_count === 1, `digest bucket: ${JSON.stringify(bucket1)}`)
  console.log(`✓ Digest bucket: count=${bucket1[0].item_count}`)

  const { commentId: comment2 } = await insertMentionComment(aliceToken, '#2')
  console.log(`✓ Comentari 2 creat: ${comment2}`)
  await processQueue()

  const bucket2 = dbQuery(`SELECT item_count FROM data.notification_digest_buckets WHERE recipient_id::text = '${CHARLIE_ID}' AND entity_id::text = '${CHARLIE_EMPLOYEE_ID}'`)
  assert(bucket2[0]?.item_count === 2, `expected digest count 2, got ${bucket2[0]?.item_count}`)
  console.log(`✓ Digest bucket acumulat: count=2`)

  const notifCount = dbQuery(`SELECT count(*)::int AS n FROM data.notifications WHERE user_id::text = '${CHARLIE_ID}' AND kind = 'mention_created' AND body_i18n->>'ca' LIKE '%Prova E2E menció%'`)
  assert(notifCount[0]?.n === 2, `expected 2 in-app notifications, got ${notifCount[0]?.n}`)
  console.log(`✓ 2 notificacions in-app (una per menció)`)

  dbQuery(`UPDATE data.notification_digest_buckets SET flush_after = now() - interval '1 second' WHERE recipient_id::text = '${CHARLIE_ID}'`)
  const workerFlush = await processQueue()
  const digest = workerFlush.digest ?? {}
  assert((digest.flushed ?? 0) >= 1, `digest flush expected: ${JSON.stringify(workerFlush)}`)
  console.log(`✓ Digest flush: flushed=${digest.flushed}, sent=${digest.sent}`)

  const digestDelivery = dbQuery(`SELECT channel::text AS channel, status::text AS status, error_code, correlation_id FROM data.notification_deliveries WHERE correlation_id LIKE 'digest:%' AND channel::text = 'push' ORDER BY created_at DESC LIMIT 1`)
  assert(digestDelivery.length === 1, 'no digest push delivery row')
  const pushStatus = digestDelivery[0].status
  const pushOk = pushStatus === 'sent'
    || (pushStatus === 'failed' && /onesignal/i.test(digestDelivery[0].error_code ?? ''))
  assert(pushOk, `unexpected digest push status: ${JSON.stringify(digestDelivery[0])}`)
  console.log(`✓ Push digest processat (status=${pushStatus}${pushStatus === 'failed' ? ', OneSignal no configurat — OK en local' : ''})`)

  const bucketsLeft = dbQuery(`SELECT count(*)::int AS n FROM data.notification_digest_buckets WHERE recipient_id::text = '${CHARLIE_ID}'`)
  assert(bucketsLeft[0]?.n === 0, 'digest bucket should be empty after flush')
  console.log('✓ Bucket digest buidat')

  console.log('\n── Resultat: TOTS ELS PASSOS OK ──\n')
}

main().catch((err) => {
  console.error('\n✗', err.message)
  process.exit(1)
})
