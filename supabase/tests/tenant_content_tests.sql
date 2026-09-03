-- =============================================================================
-- tenant_content_tests.sql — TCMS-1 F2
-- =============================================================================

BEGIN;

CREATE TEMP TABLE tcms_f2_results (
  test_name text,
  status    text,
  details   text
) ON COMMIT DROP;

-- Ensure Acme has effective portals (pro plan + flags)
UPDATE data.tenants
SET public_portal_enabled = true,
    employee_portal_enabled = true
WHERE id = '10000000-0000-0000-0000-000000000001';

-- Acme Corp (pro / basic CMS tier)
-- tenant: 10000000-0000-0000-0000-000000000001
-- public_site: 80000000-0000-0000-0000-000000000001

CREATE OR REPLACE FUNCTION pg_temp.tcms_f2_set_owner_jwt()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM set_config(
    'request.jwt.claims',
    '{"sub":"20000000-0000-0000-0000-000000000002","app_metadata":{"user_tenants":{"10000000-0000-0000-0000-000000000001":{"global_role":"owner","sites":{}}}}}',
    true
  );
  PERFORM set_config(
    'request.headers',
    '{"x-tenant-id":"10000000-0000-0000-0000-000000000001"}',
    true
  );
  SET LOCAL ROLE authenticated;
END;
$$;

-- T1: dual publish syncs public_pages
DO $$
DECLARE
  v_item_id uuid;
  v_page_id uuid;
  v_slug    text := 'tcms-dual-' || substr(md5(random()::text), 1, 8);
BEGIN
  INSERT INTO data.tenant_content_items (
    tenant_id, slug, title, content, status,
    employee_channel_enabled, public_channel_enabled, public_site_id
  ) VALUES (
    '10000000-0000-0000-0000-000000000001',
    v_slug,
    'Dual item',
    '{"html":"<p>dual</p>"}'::jsonb,
    'published',
    true, true,
    '80000000-0000-0000-0000-000000000001'
  )
  RETURNING id INTO v_item_id;

  v_page_id := data.sync_content_item_to_public_page(v_item_id);

  IF v_page_id IS NULL THEN
    INSERT INTO tcms_f2_results VALUES ('T1_dual_publish_sync', 'FAIL', 'no page id');
  ELSIF NOT EXISTS (
    SELECT 1 FROM data.public_pages
    WHERE id = v_page_id AND slug = v_slug AND status = 'published'
  ) THEN
    INSERT INTO tcms_f2_results VALUES ('T1_dual_publish_sync', 'FAIL', 'page row missing');
  ELSE
    INSERT INTO tcms_f2_results VALUES ('T1_dual_publish_sync', 'PASS', v_page_id::text);
  END IF;
END $$;

-- T2: department audience filter on employee RPC
DO $$
DECLARE
  v_slug   text := 'tcms-dept-' || substr(md5(random()::text), 1, 8);
  v_dept   uuid := '43000000-0000-0000-0000-000000000004'; -- Taller
  v_emp_a  uuid := '40000000-0000-0000-0000-000000000005';
  v_emp_b  uuid := '40000000-0000-0000-0000-000000000006';
  v_list_a jsonb;
  v_list_b jsonb;
BEGIN
  UPDATE data.employees SET department_id = v_dept WHERE id = v_emp_a;
  UPDATE data.employees SET department_id = '43000000-0000-0000-0000-000000000002' WHERE id = v_emp_b;

  INSERT INTO data.tenant_content_items (
    tenant_id, content_type, slug, title, content, status,
    employee_channel_enabled, employee_audience_scope, employee_audience_department_ids,
    published_at
  ) VALUES (
    '10000000-0000-0000-0000-000000000001',
    'announcement', v_slug, 'Dept only', '{"html":"<p>x</p>"}'::jsonb, 'published',
    true, 'departments', ARRAY[v_dept], now()
  );

  v_list_a := api.employee_portal_list_content(v_emp_a, '10000000-0000-0000-0000-000000000001');
  v_list_b := api.employee_portal_list_content(v_emp_b, '10000000-0000-0000-0000-000000000001');

  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_list_a->'items') x WHERE x->>'slug' = v_slug
  ) AND NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_list_b->'items') x WHERE x->>'slug' = v_slug
  ) THEN
    INSERT INTO tcms_f2_results VALUES ('T2_department_audience', 'PASS', NULL);
  ELSE
    INSERT INTO tcms_f2_results VALUES (
      'T2_department_audience', 'FAIL',
      jsonb_build_object('a', v_list_a, 'b', v_list_b)::text
    );
  END IF;
END $$;

-- T3: basic tier rejects sticky via upsert RPC
DO $$
DECLARE
  v_result jsonb;
BEGIN
  PERFORM pg_temp.tcms_f2_set_owner_jwt();

  v_result := api.upsert_tenant_content_item(
    '10000000-0000-0000-0000-000000000001'::uuid,
    jsonb_build_object(
      'slug', 'tcms-sticky-' || substr(md5(random()::text), 1, 8),
      'title', 'Sticky test',
      'employee_channel_enabled', true,
      'is_sticky', true,
      'content', jsonb_build_object('html', '<p>s</p>')
    )
  );

  SET LOCAL ROLE postgres;

  IF COALESCE((v_result->>'ok')::boolean, false) THEN
    INSERT INTO tcms_f2_results VALUES ('T3_basic_rejects_sticky', 'FAIL', v_result::text);
  ELSIF v_result->>'code' = 'cms_tier_insufficient' THEN
    INSERT INTO tcms_f2_results VALUES ('T3_basic_rejects_sticky', 'PASS', v_result->>'message');
  ELSE
    INSERT INTO tcms_f2_results VALUES ('T3_basic_rejects_sticky', 'FAIL', v_result::text);
  END IF;
END $$;

-- T4: backfill — every public_page has a tenant_content_item
INSERT INTO tcms_f2_results
SELECT
  'T4_backfill_all_pages',
  CASE WHEN missing = 0 THEN 'PASS' ELSE 'FAIL' END,
  missing::text
FROM (
  SELECT COUNT(*)::integer AS missing
  FROM data.public_pages pp
  WHERE NOT EXISTS (
    SELECT 1 FROM data.tenant_content_items t WHERE t.public_page_id = pp.id
  )
) s;

-- T5: same slug on different public_site_id allowed
DO $$
DECLARE
  v_slug text := 'tcms-contact';
BEGIN
  INSERT INTO data.public_sites (id, tenant_id, site_id, slug, name, status)
  VALUES (
    '80000000-0000-0000-0000-000000000099',
    '10000000-0000-0000-0000-000000000001',
    '30000000-0000-0000-0000-000000000002',
    'acme-sants-web',
    'Acme Sants Web',
    'published'
  )
  ON CONFLICT (id) DO UPDATE SET
    site_id = EXCLUDED.site_id,
    slug = EXCLUDED.slug,
    name = EXCLUDED.name;

  DELETE FROM data.tenant_content_items
  WHERE tenant_id = '10000000-0000-0000-0000-000000000001'
    AND slug = v_slug
    AND public_site_id IN (
      '80000000-0000-0000-0000-000000000001',
      '80000000-0000-0000-0000-000000000099'
    );

  INSERT INTO data.tenant_content_items (
    tenant_id, slug, title, content,
    employee_channel_enabled, public_channel_enabled, public_site_id
  ) VALUES
    ('10000000-0000-0000-0000-000000000001', v_slug, 'Contact A', '{"html":""}'::jsonb,
     false, true, '80000000-0000-0000-0000-000000000001'),
    ('10000000-0000-0000-0000-000000000001', v_slug, 'Contact B', '{"html":""}'::jsonb,
     false, true, '80000000-0000-0000-0000-000000000099');

  INSERT INTO tcms_f2_results VALUES ('T5_same_slug_two_sites', 'PASS', v_slug);
EXCEPTION WHEN unique_violation THEN
  INSERT INTO tcms_f2_results VALUES ('T5_same_slug_two_sites', 'FAIL', SQLERRM);
END $$;

-- T6: public channel without site rejected by CHECK
DO $$
BEGIN
  INSERT INTO data.tenant_content_items (
    tenant_id, slug, title, content,
    employee_channel_enabled, public_channel_enabled, public_site_id
  ) VALUES (
    '10000000-0000-0000-0000-000000000001',
    'tcms-bad-check',
    'Bad',
    '{"html":""}'::jsonb,
    false, true, NULL
  );
  INSERT INTO tcms_f2_results VALUES ('T6_public_site_check', 'FAIL', 'insert succeeded');
EXCEPTION WHEN check_violation THEN
  INSERT INTO tcms_f2_results VALUES ('T6_public_site_check', 'PASS', SQLERRM);
END $$;

DO $$
DECLARE
  v_fail integer;
  v_row  record;
BEGIN
  SELECT COUNT(*) INTO v_fail FROM tcms_f2_results WHERE status <> 'PASS';
  IF v_fail > 0 THEN
    FOR v_row IN SELECT * FROM tcms_f2_results WHERE status <> 'PASS' LOOP
      RAISE NOTICE 'FAIL %: % — %', v_row.test_name, v_row.status, v_row.details;
    END LOOP;
    RAISE EXCEPTION 'TCMS F2 tests failed: %', v_fail;
  END IF;
  RAISE NOTICE 'TCMS F2: all tests passed';
END $$;

ROLLBACK;
