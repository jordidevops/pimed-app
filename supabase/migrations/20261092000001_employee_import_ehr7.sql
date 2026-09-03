-- =============================================================================
-- EHR-7 — Import CSV ampliat (V2 directory + private gated + signed review)
-- Connectors Holded/PayFit/EI3–EI6: OUT OF SCOPE (backlog)
-- =============================================================================

-- ─── Resolvers ───────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION data.resolve_job_position_ref(
  p_tenant_id uuid,
  p_ref text
)
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_ref text := NULLIF(btrim(COALESCE(p_ref, '')), '');
  v_id uuid;
BEGIN
  IF v_ref IS NULL THEN
    RETURN NULL;
  END IF;

  -- UUID literal
  IF v_ref ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    SELECT jp.id INTO v_id
    FROM data.job_positions jp
    WHERE jp.tenant_id = p_tenant_id AND jp.id = v_ref::uuid AND jp.is_active
    LIMIT 1;
    IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  END IF;

  -- code
  SELECT jp.id INTO v_id
  FROM data.job_positions jp
  WHERE jp.tenant_id = p_tenant_id
    AND jp.code IS NOT NULL
    AND lower(btrim(jp.code)) = lower(v_ref)
    AND jp.is_active
  LIMIT 1;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;

  -- name
  SELECT jp.id INTO v_id
  FROM data.job_positions jp
  WHERE jp.tenant_id = p_tenant_id
    AND lower(btrim(jp.name)) = lower(v_ref)
    AND jp.is_active
  LIMIT 1;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION data.resolve_job_position_ref(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.resolve_job_position_ref(uuid, text) TO service_role;

CREATE OR REPLACE FUNCTION data.resolve_manager_employee_ref(
  p_tenant_id uuid,
  p_ref text,
  p_provider text DEFAULT 'csv'
)
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_ref text := NULLIF(btrim(COALESCE(p_ref, '')), '');
  v_id uuid;
  v_doc text;
  v_provider text := lower(trim(COALESCE(NULLIF(p_provider, ''), 'csv')));
BEGIN
  IF v_ref IS NULL THEN
    RETURN NULL;
  END IF;

  IF v_ref ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    SELECT e.id INTO v_id FROM data.employees e
    WHERE e.tenant_id = p_tenant_id AND e.id = v_ref::uuid LIMIT 1;
    IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  END IF;

  -- employee_code
  SELECT e.id INTO v_id FROM data.employees e
  WHERE e.tenant_id = p_tenant_id
    AND e.employee_code IS NOT NULL
    AND lower(btrim(e.employee_code)) = lower(v_ref)
  LIMIT 1;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;

  -- NIF
  v_doc := data.normalize_document_id(v_ref);
  IF v_doc IS NOT NULL THEN
    SELECT e.id INTO v_id FROM data.employees e
    WHERE e.tenant_id = p_tenant_id
      AND data.normalize_document_id(e.document_id) = v_doc
    ORDER BY e.updated_at DESC LIMIT 1;
    IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  END IF;

  -- external mapping
  SELECT m.internal_id INTO v_id
  FROM data.external_entity_mappings m
  WHERE m.tenant_id = p_tenant_id
    AND m.provider = v_provider
    AND m.entity_type = 'employee'
    AND m.external_id = v_ref
  LIMIT 1;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION data.resolve_manager_employee_ref(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.resolve_manager_employee_ref(uuid, text, text) TO service_role;

CREATE OR REPLACE FUNCTION data.import_apply_employee_tags(
  p_tenant_id uuid,
  p_employee_id uuid,
  p_tags_raw text,
  p_actor uuid
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_parts text[];
  v_name text;
  v_tag_id uuid;
  v_ids uuid[] := ARRAY[]::uuid[];
  v_count int := 0;
BEGIN
  IF p_tags_raw IS NULL OR btrim(p_tags_raw) = '' THEN
    RETURN 0;
  END IF;

  v_parts := regexp_split_to_array(p_tags_raw, '[,|;]');
  FOREACH v_name IN ARRAY v_parts LOOP
    v_name := NULLIF(btrim(v_name), '');
    IF v_name IS NULL THEN CONTINUE; END IF;

    SELECT t.id INTO v_tag_id
    FROM data.employee_tags t
    WHERE t.tenant_id = p_tenant_id AND lower(btrim(t.name)) = lower(v_name)
    LIMIT 1;

    IF v_tag_id IS NULL THEN
      INSERT INTO data.employee_tags (tenant_id, name)
      VALUES (p_tenant_id, v_name)
      RETURNING id INTO v_tag_id;
    END IF;

    IF v_tag_id IS NOT NULL AND NOT (v_tag_id = ANY (v_ids)) THEN
      v_ids := array_append(v_ids, v_tag_id);
    END IF;
  END LOOP;

  DELETE FROM data.employee_tag_assignments WHERE employee_id = p_employee_id;

  IF array_length(v_ids, 1) IS NOT NULL THEN
    INSERT INTO data.employee_tag_assignments (tenant_id, employee_id, tag_id, assigned_by)
    SELECT p_tenant_id, p_employee_id, x, p_actor
    FROM unnest(v_ids) AS x;
    v_count := array_length(v_ids, 1);
  END IF;

  RETURN COALESCE(v_count, 0);
END;
$$;

REVOKE ALL ON FUNCTION data.import_apply_employee_tags(uuid, uuid, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.import_apply_employee_tags(uuid, uuid, text, uuid) TO service_role;

-- ─── Import bulk EHR-7 ───────────────────────────────────────────────────────

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
  v_user uuid := auth.uid();
  v_dry boolean := COALESCE((p_options->>'dry_run')::boolean, false);
  v_default_site uuid := NULLIF(p_options->>'default_site_id', '')::uuid;
  v_default_provider text := lower(trim(COALESCE(p_options->>'default_provider', 'csv')));
  v_update_mode text := COALESCE(p_options->>'update_mode', 'overwrite');
  v_force_email boolean := COALESCE((p_options->>'force_email_match')::boolean, false);
  v_created int := 0;
  v_updated int := 0;
  v_skipped int := 0;
  v_needs_review int := 0;
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
  -- EHR-7
  v_code text;
  v_legal text;
  v_preferred text;
  v_job_ref text;
  v_job_pos uuid;
  v_mgr_ref text;
  v_mgr_id uuid;
  v_tags_raw text;
  v_private jsonb;
  v_can_private boolean;
  v_private_applied boolean;
  v_private_skipped text;
  v_contract_domain text;
  v_signed record;
  v_hours_conflict boolean;
  v_starts_conflict boolean;
  v_ends_conflict boolean;
  v_apply_hours numeric;
  v_apply_starts date;
  v_apply_ends date;
  v_warn jsonb;
  v_forbidden text[];
  v_meta jsonb;
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
    v_private_applied := false;
    v_private_skipped := NULL;
    v_contract_domain := 'deferred_ec';
    v_warn := '[]'::jsonb;
    v_hours_conflict := false;
    v_starts_conflict := false;
    v_ends_conflict := false;

    BEGIN
      v_full_name := NULLIF(trim(COALESCE(v_row->>'full_name', '')), '');
      IF v_full_name IS NULL THEN
        v_skipped := v_skipped + 1;
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
          'row', v_idx, 'code', 'FULL_NAME_REQUIRED', 'message', 'full_name és obligatori'
        ));
        v_results := v_results || jsonb_build_array(jsonb_build_object(
          'row', v_idx, 'action', 'error', 'code', 'FULL_NAME_REQUIRED',
          'domains', jsonb_build_object('employee', false, 'private', false, 'contract', 'deferred_ec')
        ));
        CONTINUE;
      END IF;

      -- Strip forbidden contract/category keys from metadata (never persist)
      v_meta := COALESCE(v_row->'metadata', '{}'::jsonb);
      v_forbidden := ARRAY[
        'category', 'categoria', 'conveni', 'contract', 'contract_type',
        'contract_type_id', 'salary', 'sou', 'payroll', 'nomina'
      ];
      IF v_meta ?| v_forbidden THEN
        v_warn := v_warn || jsonb_build_array(jsonb_build_object(
          'code', 'METADATA_CONTRACT_STRIPPED',
          'message', 'Camps de contracte/categoria a metadata ignorats (delegats a EC)'
        ));
        v_meta := v_meta - v_forbidden;
      END IF;
      -- Also ignore top-level forbidden aliases if present
      IF v_row ?| ARRAY['contract_type', 'conveni', 'category', 'salary'] THEN
        v_warn := v_warn || jsonb_build_array(jsonb_build_object(
          'code', 'CONTRACT_FIELDS_IGNORED',
          'message', 'Columnes de contracte ignorades; import de contractes és EC (backlog CSV EC)'
        ));
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

      v_code := NULLIF(btrim(COALESCE(v_row->>'employee_code', '')), '');
      v_legal := NULLIF(btrim(COALESCE(v_row->>'legal_name', '')), '');
      v_preferred := NULLIF(btrim(COALESCE(v_row->>'preferred_name', '')), '');
      v_job_ref := NULLIF(btrim(COALESCE(v_row->>'job_position_ref', '')), '');
      v_mgr_ref := NULLIF(btrim(COALESCE(v_row->>'manager_external_ref', '')), '');
      v_tags_raw := NULLIF(btrim(COALESCE(v_row->>'tags', '')), '');
      v_job_pos := data.resolve_job_position_ref(v_tenant, v_job_ref);
      IF v_job_ref IS NOT NULL AND v_job_pos IS NULL THEN
        v_warn := v_warn || jsonb_build_array(jsonb_build_object(
          'code', 'JOB_POSITION_UNRESOLVED',
          'message', format('Posició no trobada: %s', v_job_ref)
        ));
      END IF;

      -- Private payload: nested object or flat columns
      v_private := COALESCE(v_row->'private', '{}'::jsonb);
      IF jsonb_typeof(v_private) <> 'object' THEN
        v_private := '{}'::jsonb;
      END IF;
      IF v_row ? 'personal_email' THEN
        v_private := v_private || jsonb_build_object('personal_email', v_row->>'personal_email');
      END IF;
      IF v_row ? 'personal_phone' THEN
        v_private := v_private || jsonb_build_object('personal_phone', v_row->>'personal_phone');
      END IF;
      IF v_row ? 'birth_date' THEN
        v_private := v_private || jsonb_build_object('birth_date', v_row->>'birth_date');
      END IF;
      IF v_row ? 'address' THEN
        v_private := v_private || jsonb_build_object('address', v_row->>'address');
      END IF;
      IF v_row ? 'postal_code' THEN
        v_private := v_private || jsonb_build_object('postal_code', v_row->>'postal_code');
      END IF;
      IF v_row ? 'city' THEN
        v_private := v_private || jsonb_build_object('city', v_row->>'city');
      END IF;
      IF v_row ? 'social_security_number' THEN
        v_private := v_private || jsonb_build_object('social_security_number', v_row->>'social_security_number');
      END IF;
      IF v_row ? 'emergency_contact_name' THEN
        v_private := v_private || jsonb_build_object('emergency_contact_name', v_row->>'emergency_contact_name');
      END IF;
      IF v_row ? 'emergency_contact_phone' THEN
        v_private := v_private || jsonb_build_object('emergency_contact_phone', v_row->>'emergency_contact_phone');
      END IF;

      -- 1) Mapping
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

      -- 1b) employee_code (EHR-7)
      IF v_emp_id IS NULL AND v_code IS NOT NULL THEN
        SELECT e.* INTO v_existing
        FROM data.employees e
        WHERE e.tenant_id = v_tenant
          AND e.employee_code IS NOT NULL
          AND lower(btrim(e.employee_code)) = lower(v_code)
        LIMIT 1;
        IF FOUND THEN
          v_emp_id := v_existing.id;
          v_matched_by := 'employee_code';
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
              'employee_id', v_existing.id, 'full_name', v_full_name,
              'domains', jsonb_build_object('employee', false, 'private', false, 'contract', 'deferred_ec')
            ));
            CONTINUE;
          END IF;
          v_emp_id := v_existing.id;
          v_matched_by := 'email';
        END IF;
      END IF;

      -- Manager resolve (after potential match so self-ref works on create later)
      v_mgr_id := data.resolve_manager_employee_ref(v_tenant, v_mgr_ref, v_provider);
      IF v_mgr_ref IS NOT NULL AND v_mgr_id IS NULL THEN
        v_warn := v_warn || jsonb_build_array(jsonb_build_object(
          'code', 'MANAGER_UNRESOLVED',
          'message', format('Manager no trobat: %s', v_mgr_ref)
        ));
      END IF;

      -- Signed contract conflict (legacy hours/dates on employees vs signed EC)
      v_apply_hours := v_hours;
      v_apply_starts := v_starts;
      v_apply_ends := v_ends;
      IF v_emp_id IS NOT NULL THEN
        SELECT c.weekly_hours, c.starts_on, c.ends_on, c.signature_status
          INTO v_signed
        FROM data.employment_contracts c
        WHERE c.tenant_id = v_tenant
          AND c.employee_id = v_emp_id
          AND c.lifecycle_status IN ('active', 'draft')
          AND c.signature_status IN ('partial', 'completed')
        ORDER BY
          CASE WHEN c.lifecycle_status = 'active' THEN 0 ELSE 1 END,
          c.starts_on DESC NULLS LAST
        LIMIT 1;

        IF FOUND THEN
          IF v_hours IS NOT NULL AND v_signed.weekly_hours IS NOT NULL
             AND v_hours IS DISTINCT FROM v_signed.weekly_hours THEN
            v_hours_conflict := true;
            v_apply_hours := NULL; -- skip overwrite
          END IF;
          IF v_starts IS NOT NULL AND v_signed.starts_on IS NOT NULL
             AND v_starts IS DISTINCT FROM v_signed.starts_on THEN
            v_starts_conflict := true;
            v_apply_starts := NULL;
          END IF;
          IF v_ends IS NOT NULL AND v_signed.ends_on IS DISTINCT FROM v_ends THEN
            -- only conflict if signed has ends_on set or CSV tries to clear/change
            IF v_signed.ends_on IS NOT NULL AND v_ends IS DISTINCT FROM v_signed.ends_on THEN
              v_ends_conflict := true;
              v_apply_ends := NULL;
            END IF;
          END IF;
          IF v_hours_conflict OR v_starts_conflict OR v_ends_conflict THEN
            v_contract_domain := 'needs_review';
            v_needs_review := v_needs_review + 1;
            v_warn := v_warn || jsonb_build_array(jsonb_build_object(
              'code', 'SIGNED_CONTRACT_REVIEW',
              'message', 'Conflicte amb contracte firmat: camps hores/dates no sobrescrits; cal revisió EC'
            ));
          ELSE
            v_contract_domain := 'no_conflict';
          END IF;
        END IF;
      END IF;

      IF v_emp_id IS NOT NULL THEN
        v_action := CASE WHEN v_contract_domain = 'needs_review' THEN 'needs_review' ELSE 'update' END;
        IF NOT v_dry THEN
          IF v_update_mode = 'fill_empty' THEN
            UPDATE data.employees e SET
              full_name = CASE WHEN e.full_name IS NULL OR e.full_name = '' THEN v_full_name ELSE e.full_name END,
              document_id = CASE WHEN e.document_id IS NULL OR trim(e.document_id) = '' THEN v_doc ELSE e.document_id END,
              email = CASE WHEN e.email IS NULL OR trim(e.email) = '' THEN v_email ELSE e.email END,
              phone = CASE WHEN e.phone IS NULL OR trim(e.phone) = '' THEN v_phone ELSE e.phone END,
              job_title = CASE WHEN e.job_title IS NULL OR trim(e.job_title) = '' THEN v_job ELSE e.job_title END,
              employee_code = CASE WHEN e.employee_code IS NULL OR trim(e.employee_code) = '' THEN v_code ELSE e.employee_code END,
              legal_name = CASE WHEN e.legal_name IS NULL OR trim(e.legal_name) = '' THEN v_legal ELSE e.legal_name END,
              preferred_name = CASE WHEN e.preferred_name IS NULL OR trim(e.preferred_name) = '' THEN v_preferred ELSE e.preferred_name END,
              job_position_id = COALESCE(e.job_position_id, v_job_pos),
              manager_employee_id = COALESCE(e.manager_employee_id, v_mgr_id),
              status = COALESCE(v_status, e.status),
              starts_on = COALESCE(e.starts_on, v_apply_starts),
              ends_on = COALESCE(e.ends_on, v_apply_ends),
              weekly_hours = COALESCE(e.weekly_hours, v_apply_hours),
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
              employee_code = COALESCE(v_code, e.employee_code),
              legal_name = COALESCE(v_legal, e.legal_name),
              preferred_name = COALESCE(v_preferred, e.preferred_name),
              job_position_id = COALESCE(v_job_pos, e.job_position_id),
              manager_employee_id = COALESCE(v_mgr_id, e.manager_employee_id),
              status = v_status,
              starts_on = COALESCE(v_apply_starts, e.starts_on),
              ends_on = COALESCE(v_apply_ends, e.ends_on),
              weekly_hours = COALESCE(v_apply_hours, e.weekly_hours),
              site_id = COALESCE(v_site, e.site_id),
              updated_at = now()
            WHERE e.id = v_emp_id AND e.tenant_id = v_tenant;
          END IF;

          IF v_ext_id IS NOT NULL THEN
            PERFORM data.upsert_employee_external_mapping(
              v_tenant, v_emp_id, v_provider, v_ext_id,
              jsonb_build_object('source', 'import', 'matched_by', v_matched_by)
            );
          END IF;

          IF v_tags_raw IS NOT NULL THEN
            PERFORM data.import_apply_employee_tags(v_tenant, v_emp_id, v_tags_raw, v_user);
          END IF;
        END IF;

        v_updated := v_updated + 1;
      ELSE
        v_action := 'create';
        IF NOT v_dry THEN
          INSERT INTO data.employees (
            tenant_id, site_id, full_name, document_id, email, phone, job_title,
            employee_code, legal_name, preferred_name, job_position_id, manager_employee_id,
            status, starts_on, ends_on, weekly_hours
          )
          VALUES (
            v_tenant, v_site, v_full_name, v_doc, v_email, v_phone, v_job,
            v_code, v_legal, v_preferred, v_job_pos, v_mgr_id,
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

          IF v_tags_raw IS NOT NULL THEN
            PERFORM data.import_apply_employee_tags(v_tenant, v_emp_id, v_tags_raw, v_user);
          END IF;
        END IF;

        v_created := v_created + 1;
      END IF;

      -- Private profile: només si el JWT porta employees.private.manage explícit
      -- (no aliases via rol manager / employees.manage — pla EHR-7 §15.1)
      IF v_private IS NOT NULL AND v_private <> '{}'::jsonb THEN
        v_can_private :=
          COALESCE(data.jwt_user_permissions() -> v_tenant::text -> 'global_permissions', '[]'::jsonb)
            ? 'employees.private.manage'
          OR COALESCE(data.jwt_user_permissions() -> v_tenant::text -> 'global_permissions', '[]'::jsonb)
            ? '*'
          OR (
            COALESCE(v_site, v_existing.site_id) IS NOT NULL
            AND COALESCE(
              data.jwt_user_permissions()
                -> v_tenant::text
                -> 'sites'
                -> COALESCE(v_site, v_existing.site_id)::text,
              '[]'::jsonb
            ) ? 'employees.private.manage'
          );
        IF NOT v_can_private THEN
          v_private_skipped := 'no_permission';
          v_warn := v_warn || jsonb_build_array(jsonb_build_object(
            'code', 'PRIVATE_SKIPPED_NO_PERMISSION',
            'message', 'Perfil privat present però sense employees.private.manage explícit al JWT'
          ));
        ELSIF v_dry THEN
          v_private_applied := true; -- preview: would apply
        ELSIF v_emp_id IS NOT NULL THEN
          INSERT INTO data.employee_private_profiles AS pp (
            employee_id, tenant_id,
            personal_email, personal_phone, birth_date,
            address, postal_code, city,
            social_security_number,
            emergency_contact_name, emergency_contact_phone
          ) VALUES (
            v_emp_id, v_tenant,
            NULLIF(btrim(COALESCE(v_private->>'personal_email', '')), ''),
            NULLIF(btrim(COALESCE(v_private->>'personal_phone', '')), ''),
            NULLIF(v_private->>'birth_date', '')::date,
            NULLIF(btrim(COALESCE(v_private->>'address', '')), ''),
            NULLIF(btrim(COALESCE(v_private->>'postal_code', '')), ''),
            NULLIF(btrim(COALESCE(v_private->>'city', '')), ''),
            NULLIF(btrim(COALESCE(v_private->>'social_security_number', '')), ''),
            NULLIF(btrim(COALESCE(v_private->>'emergency_contact_name', '')), ''),
            NULLIF(btrim(COALESCE(v_private->>'emergency_contact_phone', '')), '')
          )
          ON CONFLICT (employee_id) DO UPDATE SET
            personal_email = COALESCE(NULLIF(btrim(COALESCE(EXCLUDED.personal_email, '')), ''), pp.personal_email),
            personal_phone = COALESCE(NULLIF(btrim(COALESCE(EXCLUDED.personal_phone, '')), ''), pp.personal_phone),
            birth_date = COALESCE(EXCLUDED.birth_date, pp.birth_date),
            address = COALESCE(NULLIF(btrim(COALESCE(EXCLUDED.address, '')), ''), pp.address),
            postal_code = COALESCE(NULLIF(btrim(COALESCE(EXCLUDED.postal_code, '')), ''), pp.postal_code),
            city = COALESCE(NULLIF(btrim(COALESCE(EXCLUDED.city, '')), ''), pp.city),
            social_security_number = COALESCE(NULLIF(btrim(COALESCE(EXCLUDED.social_security_number, '')), ''), pp.social_security_number),
            emergency_contact_name = COALESCE(NULLIF(btrim(COALESCE(EXCLUDED.emergency_contact_name, '')), ''), pp.emergency_contact_name),
            emergency_contact_phone = COALESCE(NULLIF(btrim(COALESCE(EXCLUDED.emergency_contact_phone, '')), ''), pp.emergency_contact_phone),
            updated_at = now();
          v_private_applied := true;
        END IF;
      END IF;

      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'row', v_idx,
        'action', v_action,
        'matched_by', COALESCE(v_matched_by, 'create'),
        'employee_id', v_emp_id,
        'full_name', v_full_name,
        'external_id', v_ext_id,
        'provider', v_provider,
        'warnings', v_warn,
        'domains', jsonb_build_object(
          'employee', true,
          'private', CASE
            WHEN v_private_skipped IS NOT NULL THEN v_private_skipped
            WHEN v_private_applied THEN 'applied'
            ELSE 'none'
          END,
          'contract', v_contract_domain
        )
      ));

    EXCEPTION WHEN others THEN
      v_skipped := v_skipped + 1;
      v_errors := v_errors || jsonb_build_array(jsonb_build_object(
        'row', v_idx,
        'code', 'ROW_FAILED',
        'message', SQLERRM
      ));
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'row', v_idx, 'action', 'error', 'code', 'ROW_FAILED', 'message', SQLERRM,
        'domains', jsonb_build_object('employee', false, 'private', false, 'contract', 'deferred_ec')
      ));
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'dry_run', v_dry,
    'created', v_created,
    'updated', v_updated,
    'skipped', v_skipped,
    'needs_review', v_needs_review,
    'errors', v_errors,
    'results', v_results,
    'connectors', jsonb_build_object(
      'status', 'backlog',
      'note', 'Holded/PayFit/EI3–EI6 no inclosos a EHR-7'
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION api.import_employees_bulk(jsonb, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.import_employees_bulk(jsonb, jsonb)
  TO authenticated, service_role;

COMMENT ON FUNCTION api.import_employees_bulk(jsonb, jsonb) IS
  'EHR-7/EX-08.4: import bulk empleats. Match: mapping → employee_code → NIF → email → create. '
  'V2: code/names/position/manager/tags; private gated; signed contract → needs_review. '
  'Connectors Holded/PayFit: backlog.';

NOTIFY pgrst, 'reload schema';
