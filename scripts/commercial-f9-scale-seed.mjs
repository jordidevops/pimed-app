/**
 * CF-28 F9 Tall 2: generate synthetic commercial scale SQL (not committed as huge dumps).
 *
 * Profiles:
 *   mini   — local/CI orders of magnitude (default)
 *   medium — ~5k docs/requests + 20 small tenants (Docker local)
 *   full   — volumes from 09-fase §9.2 (staging only; warn if written)
 *
 * Usage:
 *   node scripts/commercial-f9-scale-seed.mjs --profile mini --out /tmp/f9-mini.sql
 *   node scripts/commercial-f9-scale-seed.mjs --profile medium --out /tmp/f9-medium.sql
 *   node scripts/commercial-f9-scale-seed.mjs --profile full --out /tmp/f9-full.sql
 *
 * Apply manually against a disposable DB. Never run `full` against shared seeds.
 */
import { writeFileSync, mkdirSync } from 'node:fs'
import { dirname } from 'node:path'
import { randomUUID } from 'node:crypto'

const args = process.argv.slice(2)
function opt(name, fallback) {
  const i = args.indexOf(name)
  if (i >= 0 && args[i + 1]) return args[i + 1]
  return fallback
}

const profile = opt('--profile', 'mini')
const outPath = opt('--out', `scripts/out/commercial-f9-scale-${profile}.sql`)

const PROFILES = {
  mini: {
    largeTenantDocs: 200,
    largeTenantLinesPerDoc: 3,
    largeTenantRequests: 200,
    largeTenantEventsPerReq: 2,
    smallTenants: 5,
    smallDocsEach: 20,
    docPrefix: 'Q-F9-',
  },
  medium: {
    largeTenantDocs: 5_000,
    largeTenantLinesPerDoc: 3,
    largeTenantRequests: 5_000,
    largeTenantEventsPerReq: 2,
    smallTenants: 20,
    smallDocsEach: 25,
    docPrefix: 'Q-F9M-',
  },
  full: {
    largeTenantDocs: 100_000,
    largeTenantLinesPerDoc: 5,
    largeTenantRequests: 100_000,
    largeTenantEventsPerReq: 5,
    smallTenants: 20,
    smallDocsEach: 50,
    docPrefix: 'Q-F9F-',
  },
}

const cfg = PROFILES[profile]
if (!cfg) {
  console.error(`Unknown profile ${profile}. Use mini|medium|full.`)
  process.exit(1)
}

if (profile === 'full') {
  console.warn(
    'WARNING: full profile is huge. Only for disposable staging. Not for repo seeds.',
  )
}

const LARGE_TENANT = '10000000-0000-0000-0000-000000000003'
const OWNER = '20000000-0000-0000-0000-000000000002'
const CLIENT = '80000000-0000-0000-0000-000000000101'
const SITE = '30000000-0000-0000-0000-000000000004'

const lines = []
const emit = (s) => lines.push(s)

emit(`-- CF-28 F9 scale seed profile=${profile}`)
emit(`-- Generated ${new Date().toISOString()}`)
emit(`-- Schema aligned with data.commercial_documents / lines / decision_requests`)
emit(`BEGIN;`)
emit(`SET LOCAL statement_timeout = 0;`)
emit(`
UPDATE data.tenants
SET settings = COALESCE(settings, '{}'::jsonb)
  || jsonb_build_object(
    'commercial',
    COALESCE(settings->'commercial', '{}'::jsonb)
      || jsonb_build_object('decision_requests_enabled', true)
  )
WHERE id = '${LARGE_TENANT}'::uuid;
`)

const projectId = randomUUID()
emit(`
INSERT INTO data.projects (
  id, tenant_id, type, name, description, status, visibility,
  site_id, client_id, created_by
) VALUES (
  '${projectId}'::uuid, '${LARGE_TENANT}'::uuid, 'work_order',
  'CF28-F9-scale-${profile}', 'Synthetic', 'active', 'company',
  '${SITE}'::uuid, '${CLIENT}'::uuid, '${OWNER}'::uuid
) ON CONFLICT DO NOTHING;
`)

emit(`
DO $$
DECLARE
  i int;
  v_doc uuid;
  v_render uuid;
  v_version uuid;
  v_hash text;
  v_subtotal numeric(14,2);
  v_tax numeric(14,2);
  v_total numeric(14,2);
  g int;
BEGIN
  FOR i IN 1..${cfg.largeTenantDocs} LOOP
    v_doc := gen_random_uuid();
    v_render := gen_random_uuid();
    v_version := gen_random_uuid();
    v_hash := 'f9-' || i::text;
    v_subtotal := (${cfg.largeTenantLinesPerDoc} * 10)::numeric;
    v_tax := round(v_subtotal * 0.21, 2);
    v_total := v_subtotal + v_tax;

    INSERT INTO data.documents (id, tenant_id, title, category, required_permissions, created_by)
    VALUES (v_render, '${LARGE_TENANT}'::uuid, 'F9 render ' || i, 'commercial', '{}', '${OWNER}'::uuid);

    INSERT INTO data.document_versions (
      id, document_id, version_number, storage_type, file_path_or_url, mime_type, created_by
    ) VALUES (
      v_version, v_render, 1, 'native', 'f9/scale/' || i || '.pdf', 'application/pdf', '${OWNER}'::uuid
    );

    INSERT INTO data.commercial_documents (
      id, tenant_id, project_id, client_id, doc_type, status, doc_number,
      content_hash, rendered_document_id, created_by,
      subtotal, total, issued_at, currency, show_prices
    ) VALUES (
      v_doc, '${LARGE_TENANT}'::uuid, '${projectId}'::uuid, '${CLIENT}'::uuid, 'quote',
      CASE WHEN i % 10 = 0 THEN 'accepted' ELSE 'issued' END,
      '${cfg.docPrefix}' || lpad(i::text, 6, '0'),
      v_hash, v_render, '${OWNER}'::uuid,
      v_subtotal, v_total, now() - ((i % 30) || ' days')::interval, 'EUR', true
    );

    FOR g IN 1..${cfg.largeTenantLinesPerDoc} LOOP
      INSERT INTO data.commercial_document_lines (
        tenant_id, document_id, kind, name, unit,
        quantity, unit_price, tax_rate, position,
        line_subtotal, line_tax, line_total
      ) VALUES (
        '${LARGE_TENANT}'::uuid, v_doc, 'service', 'Line ' || g, 'u',
        1, 10, 21, g,
        10, 2.10, 12.10
      );
    END LOOP;
  END LOOP;
END $$;
`)

emit(`
DO $$
DECLARE
  r record;
  n int := 0;
  v_req uuid;
  v_version uuid;
  v_status text;
BEGIN
  FOR r IN
    SELECT d.id, d.content_hash, d.tenant_id, d.client_id, d.rendered_document_id
    FROM data.commercial_documents d
    WHERE d.tenant_id = '${LARGE_TENANT}'::uuid
      AND d.doc_number LIKE '${cfg.docPrefix}%'
    ORDER BY d.doc_number
    LIMIT ${cfg.largeTenantRequests}
  LOOP
    n := n + 1;
    v_req := gen_random_uuid();
    v_status := CASE
      WHEN n % 7 = 0 THEN 'accepted'
      WHEN n % 11 = 0 THEN 'declined'
      ELSE 'open'
    END;

    SELECT dv.id INTO v_version
    FROM data.document_versions dv
    WHERE dv.document_id = r.rendered_document_id
    ORDER BY dv.version_number DESC
    LIMIT 1;

    IF v_version IS NULL THEN
      RAISE EXCEPTION 'missing document_version for %', r.id;
    END IF;

    INSERT INTO data.commercial_decision_requests (
      id, tenant_id, client_account_contact_id, commercial_document_id, purpose,
      status, content_hash, rendered_document_id, document_version_id,
      expires_at, client_op_id, active_provider, created_by,
      decided_at, decided_via
    ) VALUES (
      v_req, r.tenant_id, r.client_id, r.id, 'acceptance',
      v_status, r.content_hash, r.rendered_document_id, v_version,
      now() + interval '30 days', gen_random_uuid(), 'native', '${OWNER}'::uuid,
      CASE WHEN v_status IN ('accepted', 'declined') THEN now() ELSE NULL END,
      CASE WHEN v_status IN ('accepted', 'declined') THEN 'office' ELSE NULL END
    );

    INSERT INTO data.commercial_decision_events (
      tenant_id, request_id, event_type, via, content_hash, evidence
    ) VALUES (
      r.tenant_id, v_req, 'created', 'office', r.content_hash, '{}'::jsonb
    );

    IF v_status IN ('accepted', 'declined') THEN
      INSERT INTO data.commercial_decision_events (
        tenant_id, request_id, event_type, outcome, via, content_hash, evidence
      ) VALUES (
        r.tenant_id, v_req, 'decided', v_status, 'office', r.content_hash, '{}'::jsonb
      );
    ELSIF ${cfg.largeTenantEventsPerReq} > 1 THEN
      INSERT INTO data.commercial_decision_events (
        tenant_id, request_id, event_type, via, content_hash, evidence
      ) VALUES (
        r.tenant_id, v_req, 'opened', 'link', r.content_hash, '{}'::jsonb
      );
    END IF;
  END LOOP;
END $$;
`)

for (let t = 0; t < cfg.smallTenants; t += 1) {
  const tid = randomUUID()
  const smallClient = randomUUID()
  emit(`
-- small tenant ${t + 1}
INSERT INTO data.tenants (id, name, slug, is_active, settings)
VALUES (
  '${tid}'::uuid,
  'F9 Small ${t + 1}',
  'f9-small-${t + 1}-${profile}-${tid.slice(0, 8)}',
  true,
  jsonb_build_object('commercial', jsonb_build_object('decision_requests_enabled', true))
) ON CONFLICT DO NOTHING;

-- synthetic client contact (minimal columns used by FK)
INSERT INTO data.contacts (id, tenant_id, kind, display_name)
VALUES (
  '${smallClient}'::uuid, '${tid}'::uuid, 'company', 'F9 Small Client ${t + 1}'
) ON CONFLICT DO NOTHING;
`)
  emit(`
DO $$
DECLARE
  i int;
  v_doc uuid;
  v_render uuid;
  v_version uuid;
BEGIN
  FOR i IN 1..${cfg.smallDocsEach} LOOP
    v_doc := gen_random_uuid();
    v_render := gen_random_uuid();
    v_version := gen_random_uuid();
    INSERT INTO data.documents (id, tenant_id, title, category, required_permissions, created_by)
    VALUES (v_render, '${tid}'::uuid, 'small ' || i, 'commercial', '{}', NULL);
    INSERT INTO data.document_versions (
      id, document_id, version_number, storage_type, file_path_or_url, mime_type
    ) VALUES (v_version, v_render, 1, 'native', 'f9/small/${t}/' || i || '.pdf', 'application/pdf');
    INSERT INTO data.commercial_documents (
      id, tenant_id, client_id, doc_type, status, doc_number,
      content_hash, rendered_document_id, subtotal, total, issued_at
    ) VALUES (
      v_doc, '${tid}'::uuid, '${smallClient}'::uuid, 'quote', 'issued',
      'Q-S${t}-' || i::text, 's-' || i::text, v_render, 10, 12.10, now()
    );
    INSERT INTO data.commercial_document_lines (
      tenant_id, document_id, kind, name, unit,
      quantity, unit_price, tax_rate, position,
      line_subtotal, line_tax, line_total
    ) VALUES (
      '${tid}'::uuid, v_doc, 'service', 'Line 1', 'u',
      1, 10, 21, 1, 10, 2.10, 12.10
    );
  END LOOP;
END $$;
`)
}

emit(`COMMIT;`)
emit(
  `-- profile=${profile} docs≈${cfg.largeTenantDocs} requests≈${cfg.largeTenantRequests} smallTenants=${cfg.smallTenants}`,
)

mkdirSync(dirname(outPath), { recursive: true })
writeFileSync(outPath, lines.join('\n'), 'utf8')
console.log(`Wrote ${outPath} (profile=${profile})`)
console.log('Apply with: psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f', outPath)
console.log('Then: psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f scripts/commercial-f9-explain.sql')
