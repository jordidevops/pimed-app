/**
 * CF-28 F9: dual-connection first-wins for data.apply_commercial_decision_request.
 *
 * Prefer Docker+psql (no npm pg). Fallback: node `pg` if installed.
 *
 *   node supabase/tests/commercial_decision_concurrency_f9.mjs
 *
 * Env: DB_CONTAINER | PROJECT_ID, DB_USER, DB_NAME, DATABASE_URL / DB_*
 */
import { randomUUID } from 'node:crypto'
import { spawn, execFileSync } from 'node:child_process'
import { writeFileSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createRequire } from 'node:module'

const TENANT = '10000000-0000-0000-0000-000000000003'
const OWNER = '20000000-0000-0000-0000-000000000002'
const CLIENT = '80000000-0000-0000-0000-000000000101'
const SITE = '30000000-0000-0000-0000-000000000004'
const LOCK_KEY = 87228009

function dbContainer() {
  if (process.env.DB_CONTAINER) return process.env.DB_CONTAINER
  if (process.env.PROJECT_ID) return `supabase_db_${process.env.PROJECT_ID}`
  return null
}

function jwtClaimSqlLiteral() {
  return JSON.stringify({
    sub: OWNER,
    role: 'authenticated',
    app_metadata: {
      user_tenants: { [TENANT]: { global_role: 'owner', sites: {} } },
      user_permissions: {
        [TENANT]: { global_permissions: ['*'], sites: {} },
      },
    },
  }).replace(/'/g, "''")
}

function dockerPsql(sql, container, user, db) {
  const dir = mkdtempSync(join(tmpdir(), 'f9-conc-'))
  const file = join(dir, 'q.sql')
  writeFileSync(file, sql, 'utf8')
  try {
    execFileSync('docker', ['cp', file, `${container}:/tmp/f9_conc.sql`], {
      stdio: 'ignore',
    })
    return execFileSync(
      'docker',
      [
        'exec',
        container,
        'psql',
        '-v',
        'ON_ERROR_STOP=1',
        '-U',
        user,
        '-d',
        db,
        '-t',
        '-A',
        '-f',
        '/tmp/f9_conc.sql',
      ],
      { encoding: 'utf8' },
    )
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

function dockerExecPsql(container, user, db, sql) {
  return new Promise((resolve, reject) => {
    const p = spawn(
      'docker',
      [
        'exec',
        '-i',
        container,
        'psql',
        '-v',
        'ON_ERROR_STOP=1',
        '-U',
        user,
        '-d',
        db,
        '-t',
        '-A',
      ],
      { stdio: ['pipe', 'pipe', 'pipe'] },
    )
    let out = ''
    let err = ''
    p.stdout.on('data', (d) => {
      out += d.toString()
    })
    p.stderr.on('data', (d) => {
      err += d.toString()
    })
    p.on('close', (code) => {
      if (code !== 0) reject(new Error(err || out || `exit ${code}`))
      else resolve(out)
    })
    p.stdin.write(sql)
    p.stdin.end()
  })
}

function parseJsonResult(stdout) {
  const line = stdout
    .split('\n')
    .map((l) => l.trim())
    .find((l) => l.startsWith('{'))
  if (!line) throw new Error(`no json in: ${stdout}`)
  return JSON.parse(line)
}

function buildSetupSql(projectId, quoteOp, reqOp) {
  return `
DO $$
DECLARE
  v_project uuid := '${projectId}'::uuid;
  v_quote uuid;
  v_render uuid;
  v_req uuid;
BEGIN
  UPDATE data.tenants
  SET settings = COALESCE(settings, '{}'::jsonb)
    || jsonb_build_object(
      'commercial',
      COALESCE(settings->'commercial', '{}'::jsonb)
        || jsonb_build_object('decision_requests_enabled', true)
    )
  WHERE id = '${TENANT}'::uuid;

  PERFORM set_config('request.jwt.claim.sub', '${OWNER}', true);
  PERFORM set_config('request.jwt.claim', '${jwtClaimSqlLiteral()}', true);
  PERFORM set_config('request.headers', '{"x-tenant-id":"${TENANT}"}', true);

  INSERT INTO data.projects (
    id, tenant_id, type, name, description, status, visibility,
    site_id, client_id, created_by
  ) VALUES (
    v_project, '${TENANT}'::uuid, 'work_order', 'CF28-F9-concurrency', 'Disposable',
    'active', 'company', '${SITE}'::uuid, '${CLIENT}'::uuid, '${OWNER}'::uuid
  );

  PERFORM api.upsert_project_line(
    v_project, NULL, NULL, 'service', 'CF28 F9 line', NULL, 'u',
    1, 100, 0, 21, 0, NULL, gen_random_uuid()
  );

  v_quote := api.issue_commercial_document(v_project, 'quote', true, '${quoteOp}'::uuid, NULL);

  INSERT INTO data.documents (tenant_id, title, category, required_permissions, created_by)
  VALUES ('${TENANT}'::uuid, 'CF28 F9 render', 'commercial', '{}', '${OWNER}'::uuid)
  RETURNING id INTO v_render;

  INSERT INTO data.document_versions (
    document_id, version_number, storage_type, file_path_or_url, mime_type, created_by
  ) VALUES (
    v_render, 1, 'native', 'cf28/f9.pdf', 'application/pdf', '${OWNER}'::uuid
  );

  UPDATE data.commercial_documents
  SET rendered_document_id = v_render,
      content_hash = COALESCE(NULLIF(btrim(content_hash), ''), 'cf28-f9-' || id::text)
  WHERE id = v_quote;

  v_req := api.create_commercial_decision_request(
    'commercial_document', v_quote, now() + interval '7 days', '${reqOp}'::uuid
  );

  PERFORM set_config('app.f9_request_id', v_req::text, false);
END $$;
SELECT current_setting('app.f9_request_id', true);
`
}

function applySql(requestId, outcome, opId) {
  return `
BEGIN;
SELECT set_config('request.jwt.claim.sub', '${OWNER}', true);
SELECT pg_advisory_xact_lock(${LOCK_KEY});
SELECT data.apply_commercial_decision_request(
  '${requestId}'::uuid, '${outcome}', 'office',
  jsonb_build_object('method', 'office', 'f9_concurrency', true),
  '${opId}'::uuid, '${OWNER}'::uuid
)::text;
COMMIT;
`
}

function assertRace(resultA, resultB, status, decidedCount) {
  const applied = [resultA, resultB].filter((r) => r?.applied === true)
  const already = [resultA, resultB].filter((r) => r?.already_decided === true)
  if (applied.length !== 1 || already.length !== 1) {
    throw new Error(
      `race flags wrong A=${JSON.stringify(resultA)} B=${JSON.stringify(resultB)}`,
    )
  }
  if (status !== 'accepted' && status !== 'declined') {
    throw new Error(`bad status ${status}`)
  }
  if (decidedCount !== 1) {
    throw new Error(`expected 1 decided event, got ${decidedCount}`)
  }
}

async function runDockerConcurrency() {
  const container = dbContainer()
  if (!container) return false
  const user = process.env.DB_USER ?? 'postgres'
  const db = process.env.DB_NAME ?? 'postgres'

  try {
    execFileSync('docker', ['inspect', container], { stdio: 'ignore' })
  } catch {
    return false
  }

  const setupResult = dockerPsql(
    buildSetupSql(randomUUID(), randomUUID(), randomUUID()),
    container,
    user,
    db,
  )
  const requestId = setupResult
    .split('\n')
    .map((l) => l.trim())
    .find((l) => /^[0-9a-f-]{36}$/i.test(l))
  if (!requestId) throw new Error(`setup failed: ${setupResult}`)

  const gate = spawn(
    'docker',
    [
      'exec',
      '-i',
      container,
      'psql',
      '-v',
      'ON_ERROR_STOP=1',
      '-U',
      user,
      '-d',
      db,
    ],
    { stdio: ['pipe', 'pipe', 'pipe'] },
  )
  gate.stdin.write(`BEGIN;\nSELECT pg_advisory_xact_lock(${LOCK_KEY});\n`)
  await new Promise((r) => setTimeout(r, 250))

  const pA = dockerExecPsql(
    container,
    user,
    db,
    applySql(requestId, 'accepted', randomUUID()),
  )
  const pB = dockerExecPsql(
    container,
    user,
    db,
    applySql(requestId, 'declined', randomUUID()),
  )
  await new Promise((r) => setTimeout(r, 350))
  gate.stdin.write('COMMIT;\n')
  gate.stdin.end()

  const [outA, outB] = await Promise.all([pA, pB])
  const resultA = parseJsonResult(outA)
  const resultB = parseJsonResult(outB)

  const verify = dockerPsql(
    `
SELECT status FROM data.commercial_decision_requests WHERE id = '${requestId}'::uuid;
SELECT count(*)::text FROM data.commercial_decision_events
WHERE request_id = '${requestId}'::uuid AND event_type = 'decided';
`,
    container,
    user,
    db,
  )
  const lines = verify
    .split('\n')
    .map((l) => l.trim())
    .filter(Boolean)
  assertRace(resultA, resultB, lines[0], Number(lines[1]))

  console.log('commercial_decision_concurrency_f9 OK (docker)', {
    status: lines[0],
    resultA,
    resultB,
  })
  return true
}

async function runPgPath() {
  const require = createRequire(import.meta.url)
  let Client
  try {
    ;({ Client } = require('pg'))
  } catch {
    try {
      ;({ Client } = require('../../node_modules/pg'))
    } catch {
      try {
        ;({ Client } = require('../../scripts/node_modules/pg'))
      } catch {
        return false
      }
    }
  }

  const url =
    process.env.DATABASE_URL ??
    `postgresql://${encodeURIComponent(process.env.DB_USER ?? 'postgres')}:${encodeURIComponent(process.env.DB_PASSWORD ?? 'postgres')}@${process.env.DB_HOST ?? '127.0.0.1'}:${process.env.DB_PORT ?? '54322'}/${process.env.DB_NAME ?? 'postgres'}`

  const setup = new Client({ connectionString: url })
  const a = new Client({ connectionString: url })
  const b = new Client({ connectionString: url })
  const gate = new Client({ connectionString: url })
  await setup.connect()
  await a.connect()
  await b.connect()
  await gate.connect()

  const projectId = randomUUID()
  let requestId
  try {
    await setup.query('BEGIN')
    await setup.query(`SELECT set_config('request.jwt.claim.sub', $1, true)`, [OWNER])
    await setup.query(`SELECT set_config('request.jwt.claim', $1::text, true)`, [
      JSON.stringify({
        sub: OWNER,
        role: 'authenticated',
        app_metadata: {
          user_tenants: { [TENANT]: { global_role: 'owner', sites: {} } },
          user_permissions: {
            [TENANT]: { global_permissions: ['*'], sites: {} },
          },
        },
      }),
    ])
    await setup.query(`SELECT set_config('request.headers', $1::text, true)`, [
      JSON.stringify({ 'x-tenant-id': TENANT }),
    ])
    await setup.query(
      `UPDATE data.tenants SET settings = COALESCE(settings, '{}'::jsonb)
        || jsonb_build_object('commercial', COALESCE(settings->'commercial', '{}'::jsonb)
          || jsonb_build_object('decision_requests_enabled', true))
       WHERE id = $1::uuid`,
      [TENANT],
    )
    await setup.query(
      `INSERT INTO data.projects (
        id, tenant_id, type, name, description, status, visibility,
        site_id, client_id, created_by
      ) VALUES ($1::uuid,$2::uuid,'work_order','CF28-F9-concurrency','Disposable','active','company',$3::uuid,$4::uuid,$5::uuid)`,
      [projectId, TENANT, SITE, CLIENT, OWNER],
    )
    await setup.query(
      `SELECT api.upsert_project_line($1::uuid,NULL,NULL,'service','CF28 F9 line',NULL,'u',1,100,0,21,0,NULL,$2::uuid)`,
      [projectId, randomUUID()],
    )
    const quoteRes = await setup.query(
      `SELECT api.issue_commercial_document($1::uuid,'quote',true,$2::uuid,NULL) AS id`,
      [projectId, randomUUID()],
    )
    const quoteId = quoteRes.rows[0].id
    const docRes = await setup.query(
      `INSERT INTO data.documents (tenant_id, title, category, required_permissions, created_by)
       VALUES ($1::uuid,'CF28 F9 render','commercial','{}',$2::uuid) RETURNING id`,
      [TENANT, OWNER],
    )
    const renderId = docRes.rows[0].id
    await setup.query(
      `INSERT INTO data.document_versions (document_id, version_number, storage_type, file_path_or_url, mime_type, created_by)
       VALUES ($1::uuid,1,'native','cf28/f9.pdf','application/pdf',$2::uuid)`,
      [renderId, OWNER],
    )
    await setup.query(
      `UPDATE data.commercial_documents
       SET rendered_document_id=$1::uuid,
           content_hash=COALESCE(NULLIF(btrim(content_hash),''),'cf28-f9-'||id::text)
       WHERE id=$2::uuid`,
      [renderId, quoteId],
    )
    const reqRes = await setup.query(
      `SELECT api.create_commercial_decision_request('commercial_document',$1::uuid,now()+interval '7 days',$2::uuid) AS id`,
      [quoteId, randomUUID()],
    )
    requestId = reqRes.rows[0].id
    await setup.query('COMMIT')

    await gate.query('BEGIN')
    await gate.query('SELECT pg_advisory_xact_lock($1)', [LOCK_KEY])

    const race = async (client, outcome) => {
      await client.query('BEGIN')
      await client.query(`SELECT set_config('request.jwt.claim.sub', $1, true)`, [OWNER])
      await client.query('SELECT pg_advisory_xact_lock($1)', [LOCK_KEY])
      const res = await client.query(
        `SELECT data.apply_commercial_decision_request(
          $1::uuid,$2::text,'office',jsonb_build_object('method','office'),$3::uuid,$4::uuid
        ) AS result`,
        [requestId, outcome, randomUUID(), OWNER],
      )
      await client.query('COMMIT')
      return res.rows[0].result
    }

    const pA = race(a, 'accepted')
    const pB = race(b, 'declined')
    await new Promise((r) => setTimeout(r, 200))
    await gate.query('COMMIT')
    const [resultA, resultB] = await Promise.all([pA, pB])

    const status = (
      await setup.query(
        `SELECT status FROM data.commercial_decision_requests WHERE id=$1::uuid`,
        [requestId],
      )
    ).rows[0].status
    const decided = (
      await setup.query(
        `SELECT count(*)::int AS n FROM data.commercial_decision_events
         WHERE request_id=$1::uuid AND event_type='decided'`,
        [requestId],
      )
    ).rows[0].n
    assertRace(resultA, resultB, status, decided)

    console.log('commercial_decision_concurrency_f9 OK (pg)', { status, resultA, resultB })
    return true
  } finally {
    await Promise.allSettled([setup.end(), a.end(), b.end(), gate.end()])
  }
}

async function main() {
  try {
    if (await runDockerConcurrency()) return
    if (await runPgPath()) return
    console.error(
      'No docker DB container and no pg module. Set DB_CONTAINER/PROJECT_ID or npm i pg.',
    )
    process.exitCode = 2
  } catch (err) {
    console.error('commercial_decision_concurrency_f9 FAIL', err)
    process.exitCode = 1
  }
}

main()
