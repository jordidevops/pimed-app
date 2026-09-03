#!/usr/bin/env node
/**
 * E2E smoke test — Fase 1 Submission Hub (firma pròpia)
 *
 * Comprova via PostgREST (service_role) que les submissions natives:
 *   - tenen signing_provider = 'native' i native_group_id
 *   - enllaçen sessions del mateix grup
 *   - tenen events a signing_events després de signar
 *   - passen a completed amb result_document_version_id
 *
 * Ús (després d'una firma presencial/remota manual o en CI):
 *   cd scripts
 *   SUPABASE_URL=http://127.0.0.1:54321 \
 *   SUPABASE_SERVICE_ROLE_KEY=<key> \
 *   node test-phase1-native-signing-hub.mjs
 *
 * Opcional: SUBMISSION_ID=<uuid> per validar una submission concreta
 */

const SUPABASE_URL = process.env.SUPABASE_URL ?? 'http://127.0.0.1:54321'
const SERVICE_KEY  = process.env.SUPABASE_SERVICE_ROLE_KEY ?? ''
const SUBMISSION_ID = process.env.SUBMISSION_ID ?? null

if (!SERVICE_KEY) {
  console.error('❌ Cal SUPABASE_SERVICE_ROLE_KEY (supabase status)')
  process.exit(1)
}

const headers = {
  apikey:          SERVICE_KEY,
  Authorization:   `Bearer ${SERVICE_KEY}`,
  'Content-Type':  'application/json',
}

async function rest(path, opts = {}) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, { ...opts, headers: { ...headers, ...opts.headers } })
  const text = await res.text()
  let data
  try { data = text ? JSON.parse(text) : null } catch { data = text }
  if (!res.ok) throw new Error(`REST ${path}: ${res.status} ${text.slice(0, 300)}`)
  return data
}

function ok(msg)   { console.log(`  ✓  ${msg}`) }
function fail(msg) { console.error(`  ✗  ${msg}`); return false }
function section(t) { console.log(`\n── ${t} ──`) }

let passed = 0
let failed = 0

function assert(cond, msg) {
  if (cond) { ok(msg); passed++ } else { failed++; fail(msg) }
}

async function main() {
  console.log('\n🔷  E2E Fase 1 — Native Signing Submission Hub\n')

  section('Submissions natives')
  const filter = SUBMISSION_ID
    ? `id=eq.${SUBMISSION_ID}`
    : `signing_provider=eq.native&order=created_at.desc&limit=5`

  const submissions = await rest(
    `signing_submissions?${filter}&select=id,status,signing_provider,native_group_id,result_document_version_id,signers,external_id,created_at,metadata`,
  )

  if (!Array.isArray(submissions) || submissions.length === 0) {
    console.log('  ⚠  Cap submission native trobada. Feu una firma pròpia i torneu a executar.')
    console.log('     Plantilla recomanada: «Test de firmes» (HTML)')
    process.exit(0)
  }

  ok(`Trobades ${submissions.length} submission(s) native`)

  for (const sub of submissions) {
    console.log(`\n  Submission ${sub.id} (${sub.status})`)

    assert(sub.signing_provider === 'native', 'signing_provider = native')
    assert(!!sub.native_group_id, 'native_group_id definit')
    assert(sub.external_id?.startsWith('native:'), 'external_id amb prefix native:')

    const signers = Array.isArray(sub.signers) ? sub.signers : []
    assert(signers.length > 0, `signers snapshot (${signers.length})`)

    section('Sessions enllaçades')
    const meta = (sub.metadata ?? {}) 
    const sessionIds = Array.isArray(meta.session_ids) ? meta.session_ids : []
    let sessions = []
    if (sessionIds.length > 0) {
      sessions = await rest(
        `document_signing_sessions?id=in.(${sessionIds.join(',')})` +
        `&select=id,status,signer_email,result_version_id`,
      )
    }
    assert(sessions.length > 0, `sessions via metadata (${sessions.length})`)

    const allSigned = sessions.every(s => s.status === 'signed')
    if (sub.status === 'completed') {
      assert(allSigned, 'totes les sessions signed quan submission completed')
      assert(!!sub.result_document_version_id, 'result_document_version_id definit')
    }

    section('Timeline (signing_events)')
    const events = await rest(
      `signing_events?submission_id=eq.${sub.id}&select=event_type,status_after&order=created_at.asc`,
    )
    assert(Array.isArray(events) && events.length > 0, `events (${events?.length ?? 0})`)

    const types = new Set(events.map(e => e.event_type))
    assert(types.has('submission.created'), 'event submission.created')
    if (sub.status === 'completed') {
      assert(types.has('form.completed') || types.has('submission.completed'), 'event de completació')
    }

    if (sub.status === 'completed') {
      section('Auditoria (RPC)')
      const auditRes = await fetch(`${SUPABASE_URL}/rest/v1/rpc/get_signature_audit_for_submission`, {
        method:  'POST',
        headers,
        body:    JSON.stringify({ p_submission_id: sub.id }),
      })
      const auditText = await auditRes.text()
      const audit = auditText ? JSON.parse(auditText) : []
      assert(auditRes.ok, 'RPC get_signature_audit_for_submission')
      assert(Array.isArray(audit) && audit.length > 0, `registres audit (${audit?.length ?? 0})`)
      if (audit[0]?.document_hash_after) {
        ok(`hash_after present (${audit[0].document_hash_after.slice(0, 16)}…)`)
      }
    }

    if (SUBMISSION_ID) break
  }

  console.log('\n────────────────────────────────────────')
  console.log(`  Passats: ${passed}   Fallats: ${failed}`)
  console.log('────────────────────────────────────────\n')
  process.exit(failed > 0 ? 1 : 0)
}

main().catch(err => {
  console.error('\n❌', err.message)
  process.exit(1)
})
