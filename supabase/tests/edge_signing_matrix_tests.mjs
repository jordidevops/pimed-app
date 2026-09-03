const SUPABASE_URL = process.env.SUPABASE_URL || 'http://127.0.0.1:54321'
const FUNCTIONS_BASE = `${SUPABASE_URL.replace(/\/$/, '')}/functions/v1`

const DEFAULT_TENANT_ID = '10000000-0000-0000-0000-000000000001'
const tests = []

function addTest(name, fn) {
  tests.push({ name, fn })
}

function assert(condition, message) {
  if (!condition) throw new Error(message)
}

async function readJsonSafe(res) {
  try {
    return await res.json()
  } catch {
    return null
  }
}

function getEnv(name) {
  const raw = process.env[name]
  if (!raw) return null
  const value = raw.trim()
  return value.length > 0 ? value : null
}

function requireEnvOrSkip(name) {
  const value = getEnv(name)
  if (!value) {
    throw new Error(`SKIP: ${name} not configured`)
  }
  return value
}

function resolveSource(kind) {
  if (kind === 'html') {
    const templateLocaleId = getEnv('EDGE_TEST_HTML_TEMPLATE_LOCALE_ID')
    if (templateLocaleId) {
      return {
        source_type: 'template_locale',
        source_template_locale_id: templateLocaleId,
      }
    }

    const documentVersionId = getEnv('EDGE_TEST_HTML_DOCUMENT_VERSION_ID')
    if (documentVersionId) {
      return {
        source_type: 'document_existing',
        source_document_version_id: documentVersionId,
      }
    }

    throw new Error('SKIP: missing EDGE_TEST_HTML_TEMPLATE_LOCALE_ID or EDGE_TEST_HTML_DOCUMENT_VERSION_ID')
  }

  if (kind === 'docx') {
    const templateLocaleId = getEnv('EDGE_TEST_DOCX_TEMPLATE_LOCALE_ID')
    if (templateLocaleId) {
      return {
        source_type: 'template_locale',
        source_template_locale_id: templateLocaleId,
      }
    }

    const documentVersionId = getEnv('EDGE_TEST_DOCX_DOCUMENT_VERSION_ID')
    if (documentVersionId) {
      return {
        source_type: 'document_existing',
        source_document_version_id: documentVersionId,
      }
    }

    throw new Error('SKIP: missing EDGE_TEST_DOCX_TEMPLATE_LOCALE_ID or EDGE_TEST_DOCX_DOCUMENT_VERSION_ID')
  }

  if (kind === 'pdf') {
    const documentVersionId = getEnv('EDGE_TEST_PDF_DOCUMENT_VERSION_ID')
    if (!documentVersionId) {
      throw new Error('SKIP: EDGE_TEST_PDF_DOCUMENT_VERSION_ID not configured')
    }
    return {
      source_type: 'document_existing',
      source_document_version_id: documentVersionId,
    }
  }

  throw new Error(`Unknown source kind: ${kind}`)
}

async function invokeSignDocumentRouter({ action, sourceKind, expects }) {
  const edgeJwt = requireEnvOrSkip('EDGE_TEST_JWT')
  const tenantId = getEnv('EDGE_TEST_TENANT_ID') || DEFAULT_TENANT_ID

  const signerEmail = getEnv('EDGE_TEST_SIGNER_EMAIL') || 'qa-signer@example.com'
  const signerName = getEnv('EDGE_TEST_SIGNER_NAME') || 'QA Signer'
  const requestId = `edge-matrix-${action}-${sourceKind}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`

  const body = {
    tenant_id: tenantId,
    action,
    client_request_id: requestId,
    context: {
      input: {
        qa_marker: requestId,
        amount: 123.45,
        approved: true,
      },
    },
    ...resolveSource(sourceKind),
  }

  if (action === 'sign') {
    body.signers = [
      {
        email: signerEmail,
        name: signerName,
        order: 0,
      },
    ]
  }

  const res = await fetch(`${FUNCTIONS_BASE}/sign-document-router`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${edgeJwt}`,
    },
    body: JSON.stringify(body),
  })

  const json = await readJsonSafe(res)

  assert(
    res.status === expects.status,
    `Expected status ${expects.status}, got ${res.status}. Response=${JSON.stringify(json)}`,
  )

  assert(
    json?.action === action,
    `Expected action=${action}, got ${json?.action}. Response=${JSON.stringify(json)}`,
  )

  if (action === 'generate_only') {
    assert(
      typeof json?.document_id === 'string' && json.document_id.length > 0,
      `Expected generate_only response with document_id, got ${JSON.stringify(json)}`,
    )
  }

  if (action === 'sign') {
    assert(
      typeof json?.submission_id === 'string' && json.submission_id.length > 0,
      `Expected sign response with submission_id, got ${JSON.stringify(json)}`,
    )
    assert(
      typeof json?.status === 'string' && json.status.length > 0,
      `Expected sign response with status, got ${JSON.stringify(json)}`,
    )
  }
}

addTest('sign/html returns 201', async () => {
  await invokeSignDocumentRouter({
    action: 'sign',
    sourceKind: 'html',
    expects: { status: 201 },
  })
})

addTest('sign/docx returns 201', async () => {
  await invokeSignDocumentRouter({
    action: 'sign',
    sourceKind: 'docx',
    expects: { status: 201 },
  })
})

addTest('sign/pdf returns 201', async () => {
  await invokeSignDocumentRouter({
    action: 'sign',
    sourceKind: 'pdf',
    expects: { status: 201 },
  })
})

addTest('generate_only/html returns 201', async () => {
  await invokeSignDocumentRouter({
    action: 'generate_only',
    sourceKind: 'html',
    expects: { status: 201 },
  })
})

addTest('generate_only/docx returns 201', async () => {
  await invokeSignDocumentRouter({
    action: 'generate_only',
    sourceKind: 'docx',
    expects: { status: 201 },
  })
})

addTest('generate_only/pdf returns 201', async () => {
  await invokeSignDocumentRouter({
    action: 'generate_only',
    sourceKind: 'pdf',
    expects: { status: 201 },
  })
})

async function main() {
  let pass = 0
  let fail = 0
  let skip = 0

  console.log(`Running edge signing matrix tests against: ${FUNCTIONS_BASE}`)

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
  console.error(`FAIL | edge_signing_matrix_tests bootstrap | ${err?.message || err}`)
  process.exit(1)
})
