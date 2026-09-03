-- =============================================================================
-- EX-08.4 / AP-12 — Import CSV empleats + external_entity_mappings (EI0+EI2+EI1)
-- Match: mapping → NIF → email → create
-- =============================================================================

-- ─── Helpers de normalització ────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION data.normalize_document_id(p_raw text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT NULLIF(upper(regexp_replace(trim(COALESCE(p_raw, '')), '[^A-Za-z0-9]', '', 'g')), '');
$$;

CREATE OR REPLACE FUNCTION data.normalize_email(p_raw text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT NULLIF(lower(trim(COALESCE(p_raw, ''))), '');
$$;

-- ─── Taula mappings ──────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS data.external_entity_mappings (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  provider       text NOT NULL,
  entity_type    text NOT NULL DEFAULT 'employee',
  internal_id    uuid NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  external_id    text NOT NULL,
  external_meta  jsonb NOT NULL DEFAULT '{}'::jsonb,
  last_synced_at timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT external_entity_mappings_provider_chk
    CHECK (length(trim(provider)) > 0),
  CONSTRAINT external_entity_mappings_entity_type_chk
    CHECK (entity_type IN ('employee')),
  CONSTRAINT external_entity_mappings_external_id_chk
    CHECK (length(trim(external_id)) > 0),
  CONSTRAINT external_entity_mappings_unique
    UNIQUE (tenant_id, provider, entity_type, external_id),
  CONSTRAINT external_entity_mappings_internal_unique
    UNIQUE (tenant_id, provider, entity_type, internal_id)
);

CREATE INDEX IF NOT EXISTS idx_external_entity_mappings_tenant_provider
  ON data.external_entity_mappings (tenant_id, provider, entity_type);

CREATE INDEX IF NOT EXISTS idx_external_entity_mappings_internal
  ON data.external_entity_mappings (tenant_id, internal_id);

CREATE TRIGGER trg_external_entity_mappings_updated_at
  BEFORE UPDATE ON data.external_entity_mappings
  FOR EACH ROW EXECUTE FUNCTION data.trg_set_updated_at();

ALTER TABLE data.external_entity_mappings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "external_entity_mappings_select"
  ON data.external_entity_mappings FOR SELECT
  TO authenticated
  USING (
    tenant_id = data.active_tenant_id()
    AND (data.jwt_user_tenants() ? tenant_id::text)
  );

CREATE POLICY "external_entity_mappings_write"
  ON data.external_entity_mappings FOR ALL
  TO authenticated
  USING (
    tenant_id = data.active_tenant_id()
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  )
  WITH CHECK (
    tenant_id = data.active_tenant_id()
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

CREATE OR REPLACE VIEW api.external_entity_mappings
WITH (security_invoker = true) AS
SELECT
  id,
  tenant_id,
  provider,
  entity_type,
  internal_id,
  external_id,
  external_meta,
  last_synced_at,
  created_at,
  updated_at
FROM data.external_entity_mappings;

GRANT SELECT ON api.external_entity_mappings TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.external_entity_mappings TO authenticated, service_role;

-- ─── Upsert mapping (intern) ─────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION data.upsert_employee_external_mapping(
  p_tenant_id uuid,
  p_employee_id uuid,
  p_provider text,
  p_external_id text,
  p_external_meta jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_id uuid;
  v_provider text := lower(trim(COALESCE(p_provider, '')));
  v_ext text := trim(COALESCE(p_external_id, ''));
BEGIN
  IF v_provider = '' OR v_ext = '' THEN
    RETURN NULL;
  END IF;

  INSERT INTO data.external_entity_mappings (
    tenant_id, provider, entity_type, internal_id, external_id, external_meta, last_synced_at
  )
  VALUES (
    p_tenant_id, v_provider, 'employee', p_employee_id, v_ext,
    COALESCE(p_external_meta, '{}'::jsonb), now()
  )
  ON CONFLICT (tenant_id, provider, entity_type, external_id)
  DO UPDATE SET
    internal_id = EXCLUDED.internal_id,
    external_meta = COALESCE(data.external_entity_mappings.external_meta, '{}'::jsonb)
      || COALESCE(EXCLUDED.external_meta, '{}'::jsonb),
    last_synced_at = now(),
    updated_at = now()
  RETURNING id INTO v_id;

  -- Assegura unicitat per empleat+provider (si l'external_id ha canviat)
  DELETE FROM data.external_entity_mappings m
  WHERE m.tenant_id = p_tenant_id
    AND m.provider = v_provider
    AND m.entity_type = 'employee'
    AND m.internal_id = p_employee_id
    AND m.id <> v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION data.upsert_employee_external_mapping(uuid, uuid, text, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.upsert_employee_external_mapping(uuid, uuid, text, text, jsonb)
  TO authenticated, service_role;

-- ─── Import bulk ─────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.import_employees_bulk(
  p_rows jsonb,
  p_options jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant uuid;
  v_role text;
  v_dry boolean := COALESCE((p_options->>'dry_run')::boolean, false);
  v_default_site uuid := NULLIF(p_options->>'default_site_id', '')::uuid;
  v_default_provider text := lower(trim(COALESCE(p_options->>'default_provider', 'csv')));
  v_update_mode text := COALESCE(p_options->>'update_mode', 'overwrite');
  v_force_email boolean := COALESCE((p_options->>'force_email_match')::boolean, false);
  v_created int := 0;
  v_updated int := 0;
  v_skipped int := 0;
  v_errors jsonb := '[]'::jsonb;
  v_results jsonb := '[]'::jsonb;
  v_row jsonb;
  v_idx int := 0;
  v_full_name text;
  v_doc text;
  v_email text;
  v_phone text;
  v_job text;
  v_status text;
  v_starts date;
  v_ends date;
  v_hours numeric;
  v_provider text;
  v_ext_id text;
  v_site uuid;
  v_emp_id uuid;
  v_matched_by text;
  v_action text;
  v_existing data.employees%ROWTYPE;
  v_nif_conflict text;
  v_new_id uuid;
BEGIN
  v_tenant := data.active_tenant_id();
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_role := data.jwt_user_tenants() -> v_tenant::text ->> 'global_role';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'invalid_rows' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF v_default_provider = '' THEN
    v_default_provider := 'csv';
  END IF;

  IF v_default_site IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM data.sites s WHERE s.id = v_default_site AND s.tenant_id = v_tenant
  ) THEN
    RAISE EXCEPTION 'site_not_found' USING ERRCODE = 'P0002';
  END IF;

  FOR v_row IN SELECT value FROM jsonb_array_elements(p_rows)
  LOOP
    v_idx := v_idx + 1;
    v_emp_id := NULL;
    v_matched_by := NULL;
    v_action := NULL;
    v_existing := NULL;
    v_nif_conflict := NULL;

    BEGIN
      v_full_name := NULLIF(trim(COALESCE(v_row->>'full_name', '')), '');
      IF v_full_name IS NULL THEN
        v_skipped := v_skipped + 1;
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
          'row', v_idx, 'code', 'FULL_NAME_REQUIRED', 'message', 'full_name és obligatori'
        ));
        v_results := v_results || jsonb_build_array(jsonb_build_object(
          'row', v_idx, 'action', 'error', 'code', 'FULL_NAME_REQUIRED'
        ));
        CONTINUE;
      END IF;

      v_doc := data.normalize_document_id(v_row->>'document_id');
      v_email := data.normalize_email(v_row->>'email');
      v_phone := NULLIF(trim(COALESCE(v_row->>'phone', '')), '');
      v_job := NULLIF(trim(COALESCE(v_row->>'job_title', '')), '');
      v_status := lower(trim(COALESCE(NULLIF(v_row->>'status', ''), 'active')));
      IF v_status NOT IN ('active', 'inactive', 'terminated') THEN
        v_status := 'active';
      END IF;

      BEGIN
        v_starts := NULLIF(v_row->>'starts_on', '')::date;
      EXCEPTION WHEN others THEN
        v_starts := NULL;
      END;
      BEGIN
        v_ends := NULLIF(v_row->>'ends_on', '')::date;
      EXCEPTION WHEN others THEN
        v_ends := NULL;
      END;
      BEGIN
        v_hours := NULLIF(v_row->>'weekly_hours', '')::numeric;
      EXCEPTION WHEN others THEN
        v_hours := NULL;
      END;

      v_provider := lower(trim(COALESCE(NULLIF(v_row->>'provider', ''), v_default_provider)));
      v_ext_id := NULLIF(trim(COALESCE(v_row->>'external_id', '')), '');
      v_site := COALESCE(NULLIF(v_row->>'site_id', '')::uuid, v_default_site);

      -- 1) Mapping existent
      IF v_ext_id IS NOT NULL THEN
        SELECT e.* INTO v_existing
        FROM data.external_entity_mappings m
        JOIN data.employees e ON e.id = m.internal_id AND e.tenant_id = m.tenant_id
        WHERE m.tenant_id = v_tenant
          AND m.provider = v_provider
          AND m.entity_type = 'employee'
          AND m.external_id = v_ext_id
        LIMIT 1;
        IF FOUND THEN
          v_emp_id := v_existing.id;
          v_matched_by := 'mapping';
        END IF;
      END IF;

      -- 2) NIF
      IF v_emp_id IS NULL AND v_doc IS NOT NULL THEN
        SELECT e.* INTO v_existing
        FROM data.employees e
        WHERE e.tenant_id = v_tenant
          AND data.normalize_document_id(e.document_id) = v_doc
        ORDER BY e.updated_at DESC
        LIMIT 1;
        IF FOUND THEN
          v_emp_id := v_existing.id;
          v_matched_by := 'document_id';
        END IF;
      END IF;

      -- 3) Email
      IF v_emp_id IS NULL AND v_email IS NOT NULL THEN
        SELECT e.* INTO v_existing
        FROM data.employees e
        WHERE e.tenant_id = v_tenant
          AND data.normalize_email(e.email) = v_email
        ORDER BY e.updated_at DESC
        LIMIT 1;
        IF FOUND THEN
          IF v_doc IS NOT NULL
             AND data.normalize_document_id(v_existing.document_id) IS NOT NULL
             AND data.normalize_document_id(v_existing.document_id) <> v_doc
             AND NOT v_force_email THEN
            v_nif_conflict := data.normalize_document_id(v_existing.document_id);
            v_skipped := v_skipped + 1;
            v_errors := v_errors || jsonb_build_array(jsonb_build_object(
              'row', v_idx,
              'code', 'EMAIL_NIF_MISMATCH',
              'message', format('Email coincideix amb NIF diferent (%s vs %s)', v_nif_conflict, v_doc),
              'employee_id', v_existing.id
            ));
            v_results := v_results || jsonb_build_array(jsonb_build_object(
              'row', v_idx, 'action', 'error', 'code', 'EMAIL_NIF_MISMATCH',
              'employee_id', v_existing.id, 'full_name', v_full_name
            ));
            CONTINUE;
          END IF;
          v_emp_id := v_existing.id;
          v_matched_by := 'email';
        END IF;
      END IF;

      IF v_emp_id IS NOT NULL THEN
        v_action := 'update';
        IF NOT v_dry THEN
          IF v_update_mode = 'fill_empty' THEN
            UPDATE data.employees e SET
              full_name = CASE WHEN e.full_name IS NULL OR e.full_name = '' THEN v_full_name ELSE e.full_name END,
              document_id = CASE WHEN e.document_id IS NULL OR trim(e.document_id) = '' THEN v_doc ELSE e.document_id END,
              email = CASE WHEN e.email IS NULL OR trim(e.email) = '' THEN v_email ELSE e.email END,
              phone = CASE WHEN e.phone IS NULL OR trim(e.phone) = '' THEN v_phone ELSE e.phone END,
              job_title = CASE WHEN e.job_title IS NULL OR trim(e.job_title) = '' THEN v_job ELSE e.job_title END,
              status = COALESCE(v_status, e.status),
              starts_on = COALESCE(e.starts_on, v_starts),
              ends_on = COALESCE(e.ends_on, v_ends),
              weekly_hours = COALESCE(e.weekly_hours, v_hours),
              site_id = COALESCE(e.site_id, v_site),
              updated_at = now()
            WHERE e.id = v_emp_id AND e.tenant_id = v_tenant;
          ELSE
            UPDATE data.employees e SET
              full_name = v_full_name,
              document_id = COALESCE(v_doc, e.document_id),
              email = COALESCE(v_email, e.email),
              phone = COALESCE(v_phone, e.phone),
              job_title = COALESCE(v_job, e.job_title),
              status = v_status,
              starts_on = COALESCE(v_starts, e.starts_on),
              ends_on = COALESCE(v_ends, e.ends_on),
              weekly_hours = COALESCE(v_hours, e.weekly_hours),
              site_id = COALESCE(v_site, e.site_id),
              updated_at = now()
            WHERE e.id = v_emp_id AND e.tenant_id = v_tenant;
          END IF;

          IF v_ext_id IS NOT NULL THEN
            PERFORM data.upsert_employee_external_mapping(
              v_tenant, v_emp_id, v_provider, v_ext_id,
              jsonb_build_object('source', 'import', 'matched_by', v_matched_by)
            );
          ELSIF v_matched_by IN ('document_id', 'email') AND v_ext_id IS NULL THEN
            NULL; -- sense external_id no creem mapping
          END IF;
        ELSIF v_ext_id IS NOT NULL THEN
          NULL; -- dry_run: només preview
        END IF;

        v_updated := v_updated + 1;
        v_results := v_results || jsonb_build_array(jsonb_build_object(
          'row', v_idx,
          'action', v_action,
          'matched_by', v_matched_by,
          'employee_id', v_emp_id,
          'full_name', v_full_name,
          'external_id', v_ext_id,
          'provider', v_provider
        ));
      ELSE
        v_action := 'create';
        IF NOT v_dry THEN
          INSERT INTO data.employees (
            tenant_id, site_id, full_name, document_id, email, phone, job_title,
            status, starts_on, ends_on, weekly_hours
          )
          VALUES (
            v_tenant, v_site, v_full_name, v_doc, v_email, v_phone, v_job,
            v_status, v_starts, v_ends, v_hours
          )
          RETURNING id INTO v_new_id;

          v_emp_id := v_new_id;

          IF v_ext_id IS NOT NULL THEN
            PERFORM data.upsert_employee_external_mapping(
              v_tenant, v_emp_id, v_provider, v_ext_id,
              jsonb_build_object('source', 'import', 'matched_by', 'create')
            );
          END IF;
        END IF;

        v_created := v_created + 1;
        v_results := v_results || jsonb_build_array(jsonb_build_object(
          'row', v_idx,
          'action', v_action,
          'matched_by', 'create',
          'employee_id', v_emp_id,
          'full_name', v_full_name,
          'external_id', v_ext_id,
          'provider', v_provider
        ));
      END IF;

    EXCEPTION WHEN others THEN
      v_skipped := v_skipped + 1;
      v_errors := v_errors || jsonb_build_array(jsonb_build_object(
        'row', v_idx,
        'code', 'ROW_FAILED',
        'message', SQLERRM
      ));
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'row', v_idx, 'action', 'error', 'code', 'ROW_FAILED', 'message', SQLERRM
      ));
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'dry_run', v_dry,
    'created', v_created,
    'updated', v_updated,
    'skipped', v_skipped,
    'errors', v_errors,
    'results', v_results
  );
END;
$$;

REVOKE ALL ON FUNCTION api.import_employees_bulk(jsonb, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.import_employees_bulk(jsonb, jsonb)
  TO authenticated, service_role;

COMMENT ON FUNCTION api.import_employees_bulk(jsonb, jsonb) IS
  'EX-08.4: import/actualització bulk d''empleats (CSV/ERP). Match: mapping → NIF → email → create. Opcions: dry_run, default_site_id, default_provider, update_mode, force_email_match.';
