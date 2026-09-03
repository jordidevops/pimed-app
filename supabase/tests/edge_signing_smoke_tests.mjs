import crypto from 'node:crypto'

const SUPABASE_URL = process.env.SUPABASE_URL || 'http://127.0.0.1:54321'
const FUNCTIONS_BASE = `${SUPABASE_URL.replace(/\/$/, '')}/functions/v1`

const tests = []

function addTest(name, fn) {
  tests.push({ name, fn })
}

async function readJsonSafe(res) {
  try {
    return await res.json()
  } catch {
    return null
  }
}

function assert(condition, message) {
  if (!condition) throw new Error(message)
}

addTest('sign-document-router rejects unauthenticated request', async () => {
  const body = {
    tenant_id: '10000000-0000-0000-0000-000000000001',
    action: 'generate_only',
    source_type: 'document_existing',
    source_document_version_id: '00000000-0000-0000-0000-000000000001',
  }

  const res = await fetch(`${FUNCTIONS_BASE}/sign-document-router`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  })

  const json = await readJsonSafe(res)
  assert(res.status === 401, `Expected 401, got ${res.status}`)
  void json
})

addTest('sign-document-router rejects invalid JSON body', async () => {
  const edgeJwt = process.env.EDGE_TEST_JWT
  if (!edgeJwt || edgeJwt.length === 0) {
    throw new Error('SKIP: EDGE_TEST_JWT not configured')
  }

  const res = await fetch(`${FUNCTIONS_BASE}/sign-document-router`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${edgeJwt}`,
    },
    body: '{ bad json',
  })

  const json = await readJsonSafe(res)
  assert(res.status === 400, `Expected 400, got ${res.status}`)
  assert(json?.error?.code === 'invalid_json', `Expected error.code=invalid_json, got ${json?.error?.code}`)
})

addTest('docuseal-webhook rejects invalid signature', async () => {
  const secret = process.env.DOCUSEAL_WEBHOOK_SECRET
  if (!secret || secret.length === 0) {
    throw new Error('SKIP: DOCUSEAL_WEBHOOK_SECRET not configured')
  }

  const payload = {
    event_type: 'submission.completed',
    timestamp: new Date().toISOString(),
    data: {
      id: 123,
      external_id: 'edge-smoke-invalid-signature',
    },
  }

  const raw = JSON.stringify(payload)

  const res = await fetch(`${FUNCTIONS_BASE}/docuseal-webhook`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-DocuSeal-Signature': 'invalid-signature',
    },
    body: raw,
  })

  const json = await readJsonSafe(res)
  assert(res.status === 401, `Expected 401, got ${res.status}`)
  assert((json?.error || '').includes('invalid signature'), `Expected invalid signature error, got ${json?.error}`)
})

addTest('docuseal-webhook accepts valid signature and ignores payload without external_id', async () => {
  const secret = process.env.DOCUSEAL_WEBHOOK_SECRET
  if (!secret || secret.length === 0) {
    throw new Error('SKIP: DOCUSEAL_WEBHOOK_SECRET not configured')
  }

  const payload = {
    event_type: 'submission.completed',
    timestamp: new Date().toISOString(),
    data: {
      id: 124,
    },
  }

  const raw = JSON.stringify(payload)
  const signature = crypto.createHmac('sha256', secret).update(raw).digest('hex')

  const res = await fetch(`${FUNCTIONS_BASE}/docuseal-webhook`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-DocuSeal-Signature': signature,
    },
    body: raw,
  })

  const json = await readJsonSafe(res)
  assert(res.status === 200, `Expected 200, got ${res.status}`)
  assert(json?.processed === false, `Expected processed=false, got ${json?.processed}`)
  assert(json?.reason === 'no_external_id', `Expected reason=no_external_id, got ${json?.reason}`)
})

async function main() {
  let pass = 0
  let fail = 0
  let skip = 0

  console.log(`Running edge signing smoke tests against: ${FUNCTIONS_BASE}`)

  for (const t of tests) {
    try {
      await t.fn()
      pass += 1
      console.log(`PASS | ${t.name}`)
    } catch (err) {
      if (err && err.message && err.message.startsWith('SKIP:')) {
        skip += 1
        console.log(`SKIP | ${t.name} | ${err.message.replace(/^SKIP:\s*/, '')}`)
        continue
      }
      fail += 1
      console.error(`FAIL | ${t.name} | ${(err && err.message) || err}`)
    }
  }

  console.log(`Summary: PASS=${pass} SKIP=${skip} FAIL=${fail} TOTAL=${tests.length}`)
  if (fail > 0) process.exit(1)
}

main().catch((err) => {
  console.error(`FAIL | edge_signing_smoke_tests bootstrap | ${err?.message || err}`)
  process.exit(1)
})
