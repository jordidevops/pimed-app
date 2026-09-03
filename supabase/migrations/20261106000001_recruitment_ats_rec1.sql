-- =============================================================================
-- REC-0 + REC-1 — Recruitment ATS core (MVP captura)
-- Feature flag, settings, schema, RLS, permissions, entity_types,
-- email templates, purge cron, submit/verify RPCs.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 0. Feature flag
-- ---------------------------------------------------------------------------
INSERT INTO data.feature_flags (key, description, is_enabled, rollout_percentage)
VALUES (
  'recruitment_enabled',
  'Mòdul reclutament / ATS (ofertes + captura pública).',
  false,
  0
)
ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 1. Permissions
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.get_role_permissions(
  p_role              text,
  p_custom_perms      jsonb DEFAULT NULL
)
RETURNS text[]
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_viewer_base  text[] := ARRAY[
    'storage.view', 'calendar.view', 'email.view', 'invoices.view',
    'members.view', 'sites.view', 'settings.view',
    'attendance.view_own', 'labor_calendar.view',
    'employees.directory.view',
    'assets.view',
    'recruitment.view'
  ];
  v_member_base  text[] := ARRAY[
    'storage.upload', 'calendar.edit', 'email.send', 'invoices.edit',
    'attendance.punch_own', 'absences.request',
    'ai.use',
    'employees.directory.view', 'employees.view',
    'assets.view',
    'recruitment.view'
  ];
  v_manager_base text[] := ARRAY[
    'storage.delete', 'calendar.manage', 'email.manage', 'invoices.manage',
    'members.invite', 'sites.create', 'settings.manage', 'permissions.manage',
    'attendance.view_all', 'attendance.adjust', 'attendance.approve',
    'attendance.export', 'attendance.devices.manage',
    'labor_calendar.manage', 'absences.approve',
    'ai.configure', 'ai.tools.write',
    'employees.directory.view', 'employees.view', 'employees.manage',
    'employees.private.view', 'employees.private.manage',
    'employees.skills.manage',
    'employees.lifecycle.view', 'employees.lifecycle.manage',
    'employees.contracts.view', 'employees.contracts.manage',
    'compliance.requirements.manage',
    'compliance.certifications.view', 'compliance.certifications.manage',
    'assets.view', 'assets.manage',
    'assets.employee_assignments.view', 'assets.employee_assignments.manage',
    'recruitment.view', 'recruitment.manage', 'recruitment.interview'
  ];
  v_accumulated  text[] := '{}';
BEGIN
  IF p_role = 'owner' THEN
    RETURN ARRAY['*'];
  END IF;

  IF p_custom_perms IS NOT NULL AND p_custom_perms ? 'viewer' THEN
    v_accumulated := v_accumulated ||
      ARRAY(SELECT jsonb_array_elements_text(p_custom_perms -> 'viewer'));
  ELSE
    v_accumulated := v_accumulated || v_viewer_base;
  END IF;

  IF p_role IN ('member', 'manager') THEN
    IF p_custom_perms IS NOT NULL AND p_custom_perms ? 'member' THEN
      v_accumulated := v_accumulated ||
        ARRAY(SELECT jsonb_array_elements_text(p_custom_perms -> 'member'));
    ELSE
      v_accumulated := v_accumulated || v_member_base;
    END IF;
  END IF;

  IF p_role = 'manager' THEN
    IF p_custom_perms IS NOT NULL AND p_custom_perms ? 'manager' THEN
      v_accumulated := v_accumulated ||
        ARRAY(SELECT jsonb_array_elements_text(p_custom_perms -> 'manager'));
    ELSE
      v_accumulated := v_accumulated || v_manager_base;
    END IF;
  END IF;

  RETURN ARRAY(SELECT DISTINCT unnest(v_accumulated));
END;
$$;

GRANT EXECUTE ON FUNCTION data.get_role_permissions(text, jsonb)
  TO authenticated, supabase_auth_admin;

CREATE OR REPLACE FUNCTION data.jwt_has_recruitment_permission(
  p_tenant_id  uuid,
  p_permission text,
  p_site_id    uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT data.jwt_has_permission(p_tenant_id, p_permission, p_site_id);
$$;

GRANT EXECUTE ON FUNCTION data.jwt_has_recruitment_permission(uuid, text, uuid)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Entity types
-- ---------------------------------------------------------------------------
INSERT INTO data.entity_types (
  code, label_key,
  supports_timeline, supports_documents, supports_signing, supports_subscriptions
)
SELECT v.code, v.label_key, v.tl, v.doc, v.sig, v.sub
FROM (
  VALUES
    ('job_posting', 'entity_types.job_posting', false, true,  false, false),
    ('applicant',   'entity_types.applicant',   false, false, false, false),
    ('application', 'entity_types.application', false, true,  false, false)
) AS v(code, label_key, tl, doc, sig, sub)
WHERE NOT EXISTS (
  SELECT 1 FROM data.entity_types et WHERE et.code = v.code
);

-- ---------------------------------------------------------------------------
-- 3. recruitment_settings
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.recruitment_settings (
  tenant_id                     uuid PRIMARY KEY REFERENCES data.tenants(id) ON DELETE CASCADE,
  default_max_retention_months  int NOT NULL DEFAULT 12
    CHECK (default_max_retention_months >= 1 AND default_max_retention_months <= 60),
  expire_closes_process         boolean NOT NULL DEFAULT true,
  rights_sla_days               int NOT NULL DEFAULT 30
    CHECK (rights_sla_days >= 1 AND rights_sla_days <= 90),
  rejection_notify_policy       text NOT NULL DEFAULT 'on_decision'
    CHECK (rejection_notify_policy IN ('on_decision', 'on_posting_close')),
  privacy_policy_url            text,
  import_legal_basis            text NOT NULL DEFAULT 'legitimate_interest'
    CHECK (import_legal_basis IN ('legitimate_interest', 'consent', 'other')),
  import_legal_basis_note       text,
  enforce_department_scope      boolean NOT NULL DEFAULT false,
  analytics_min_cohort          int NOT NULL DEFAULT 5
    CHECK (analytics_min_cohort >= 3 AND analytics_min_cohort <= 20),
  erasure_hmac_key              bytea NOT NULL DEFAULT gen_random_bytes(32),
  created_at                    timestamptz NOT NULL DEFAULT now(),
  updated_at                    timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE data.recruitment_settings IS
  'REC-1 tenant recruitment settings. default_max_retention_months is mandatory (Art. 5.1.e).';
COMMENT ON COLUMN data.recruitment_settings.erasure_hmac_key IS
  'Secret for applicant_erasure_log HMAC (pseudonymisation, not anonymisation). Never expose via api views.';

ALTER TABLE data.recruitment_settings ENABLE ROW LEVEL SECURITY;

CREATE POLICY recruitment_settings_select ON data.recruitment_settings
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_has_recruitment_permission(tenant_id, 'recruitment.view')
  );

CREATE POLICY recruitment_settings_update ON data.recruitment_settings
  FOR UPDATE TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      data.jwt_has_recruitment_permission(tenant_id, 'recruitment.manage')
      OR data.jwt_has_recruitment_permission(tenant_id, 'recruitment.rights')
    )
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

INSERT INTO data.recruitment_settings (tenant_id)
SELECT t.id FROM data.tenants t
WHERE NOT EXISTS (
  SELECT 1 FROM data.recruitment_settings rs WHERE rs.tenant_id = t.id
);

CREATE OR REPLACE FUNCTION data.ensure_recruitment_settings()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  INSERT INTO data.recruitment_settings (tenant_id)
  VALUES (NEW.id)
  ON CONFLICT (tenant_id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_tenants_ensure_recruitment_settings ON data.tenants;
CREATE TRIGGER trg_tenants_ensure_recruitment_settings
  AFTER INSERT ON data.tenants
  FOR EACH ROW
  EXECUTE FUNCTION data.ensure_recruitment_settings();

-- ---------------------------------------------------------------------------
-- 4. pipeline_stages (tenant defaults)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.pipeline_stages (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  job_posting_id     uuid, -- NULL = tenant template; FK added after job_postings
  name               text NOT NULL,
  position           int NOT NULL DEFAULT 0,
  is_terminal_hire   boolean NOT NULL DEFAULT false,
  is_terminal_reject boolean NOT NULL DEFAULT false,
  created_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pipeline_stages_terminal_xor CHECK (
    NOT (is_terminal_hire AND is_terminal_reject)
  )
);

CREATE INDEX IF NOT EXISTS idx_pipeline_stages_tenant
  ON data.pipeline_stages (tenant_id, job_posting_id, position);

ALTER TABLE data.pipeline_stages ENABLE ROW LEVEL SECURITY;

CREATE POLICY pipeline_stages_select ON data.pipeline_stages
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_has_recruitment_permission(tenant_id, 'recruitment.view')
  );

CREATE POLICY pipeline_stages_write ON data.pipeline_stages
  FOR ALL TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_has_recruitment_permission(tenant_id, 'recruitment.manage')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

CREATE OR REPLACE FUNCTION data.seed_default_pipeline_stages(p_tenant_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM data.pipeline_stages
    WHERE tenant_id = p_tenant_id AND job_posting_id IS NULL
  ) THEN
    RETURN;
  END IF;

  INSERT INTO data.pipeline_stages (
    tenant_id, name, position, is_terminal_hire, is_terminal_reject
  ) VALUES
    (p_tenant_id, 'Rebut', 0, false, false),
    (p_tenant_id, 'En revisió', 1, false, false),
    (p_tenant_id, 'Entrevista', 2, false, false),
    (p_tenant_id, 'Oferta', 3, false, false),
    (p_tenant_id, 'Descart', 4, false, true),
    (p_tenant_id, 'Contractat', 5, true, false);
END;
$$;

CREATE OR REPLACE FUNCTION data.trg_seed_pipeline_on_settings()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  PERFORM data.seed_default_pipeline_stages(NEW.tenant_id);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_recruitment_settings_seed_stages ON data.recruitment_settings;
CREATE TRIGGER trg_recruitment_settings_seed_stages
  AFTER INSERT ON data.recruitment_settings
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_seed_pipeline_on_settings();

SELECT data.seed_default_pipeline_stages(t.id)
FROM data.tenants t;

-- ---------------------------------------------------------------------------
-- 5. job_postings + templates + public sites M:N
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.job_posting_templates (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  name               text NOT NULL,
  title              text NOT NULL,
  description        text,
  interviewer_guide  text,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE data.job_posting_templates ENABLE ROW LEVEL SECURITY;

CREATE POLICY job_posting_templates_all ON data.job_posting_templates
  FOR ALL TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_has_recruitment_permission(tenant_id, 'recruitment.view')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_has_recruitment_permission(tenant_id, 'recruitment.manage')
  );

CREATE TABLE IF NOT EXISTS data.job_postings (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  site_id             uuid REFERENCES data.sites(id) ON DELETE SET NULL,
  department_id       uuid REFERENCES data.departments(id) ON DELETE SET NULL,
  job_position_id     uuid REFERENCES data.job_positions(id) ON DELETE SET NULL,
  location_id         uuid REFERENCES data.locations(id) ON DELETE SET NULL,
  template_id         uuid REFERENCES data.job_posting_templates(id) ON DELETE SET NULL,
  title               text NOT NULL,
  description         text,
  interviewer_guide   text,
  public_slug         text NOT NULL,
  status              text NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft', 'published', 'unlisted', 'expired', 'archived')),
  opens_at            timestamptz,
  closes_at           timestamptz,
  created_by          uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, public_slug)
);

CREATE INDEX IF NOT EXISTS idx_job_postings_tenant_status
  ON data.job_postings (tenant_id, status);

ALTER TABLE data.job_postings ENABLE ROW LEVEL SECURITY;

CREATE POLICY job_postings_select ON data.job_postings
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_has_recruitment_permission(tenant_id, 'recruitment.view', site_id)
  );

CREATE POLICY job_postings_insert ON data.job_postings
  FOR INSERT TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_has_recruitment_permission(tenant_id, 'recruitment.manage', site_id)
  );

CREATE POLICY job_postings_update ON data.job_postings
  FOR UPDATE TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_has_recruitment_permission(tenant_id, 'recruitment.manage', site_id)
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

CREATE POLICY job_postings_delete ON data.job_postings
  FOR DELETE TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_has_recruitment_permission(tenant_id, 'recruitment.manage', site_id)
  );

ALTER TABLE data.pipeline_stages
  DROP CONSTRAINT IF EXISTS pipeline_stages_job_posting_id_fkey;
ALTER TABLE data.pipeline_stages
  ADD CONSTRAINT pipeline_stages_job_posting_id_fkey
  FOREIGN KEY (job_posting_id) REFERENCES data.job_postings(id) ON DELETE CASCADE;

CREATE TABLE IF NOT EXISTS data.job_posting_public_sites (
  job_posting_id  uuid NOT NULL REFERENCES data.job_postings(id) ON DELETE CASCADE,
  public_site_id  uuid NOT NULL REFERENCES data.public_sites(id) ON DELETE CASCADE,
  tenant_id       uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  created_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (job_posting_id, public_site_id)
);

CREATE INDEX IF NOT EXISTS idx_job_posting_public_sites_site
  ON data.job_posting_public_sites (public_site_id);

ALTER TABLE data.job_posting_public_sites ENABLE ROW LEVEL SECURITY;

CREATE POLICY job_posting_public_sites_all ON data.job_posting_public_sites
  FOR ALL TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_has_recruitment_permission(tenant_id, 'recruitment.view')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_has_recruitment_permission(tenant_id, 'recruitment.manage')
  );

-- ---------------------------------------------------------------------------
-- 6. applicants + applications
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.applicants (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  email              text NOT NULL,
  full_name          text NOT NULL,
  phone              text,
  email_verified_at  timestamptz,
  email_verify_token_hash text,
  email_verify_expires_at timestamptz,
  talent_pool_until  timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, email)
);

CREATE INDEX IF NOT EXISTS idx_applicants_tenant_email
  ON data.applicants (tenant_id, lower(email));

ALTER TABLE data.applicants ENABLE ROW LEVEL SECURITY;

CREATE POLICY applicants_select ON data.applicants
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_has_recruitment_permission(tenant_id, 'recruitment.view')
  );

CREATE POLICY applicants_write ON data.applicants
  FOR ALL TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_has_recruitment_permission(tenant_id, 'recruitment.manage')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

CREATE TABLE IF NOT EXISTS data.applications (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  job_posting_id           uuid NOT NULL REFERENCES data.job_postings(id) ON DELETE CASCADE,
  applicant_id             uuid NOT NULL REFERENCES data.applicants(id) ON DELETE CASCADE,
  stage_id                 uuid REFERENCES data.pipeline_stages(id) ON DELETE SET NULL,
  cv_storage_path          text,
  retention_preference     text NOT NULL
    CHECK (retention_preference IN ('delete_on_process_end', 'delete_after_months')),
  retention_months         int
    CHECK (retention_months IS NULL OR (retention_months >= 1 AND retention_months <= 60)),
  purge_at                 timestamptz NOT NULL,
  source                   text NOT NULL DEFAULT 'web'
    CHECK (source IN ('web', 'qr', 'whatsapp', 'email', 'manual', 'csv_import')),
  import_source_label      text,
  outcome_communicated_at  timestamptz,
  process_closed_at        timestamptz,
  cover_message            text,
  legal_notice_version     text,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  UNIQUE (job_posting_id, applicant_id),
  CONSTRAINT applications_retention_months_ck CHECK (
    (retention_preference = 'delete_after_months' AND retention_months IS NOT NULL)
    OR (retention_preference = 'delete_on_process_end' AND retention_months IS NULL)
  )
);

-- Generated visibility (not writable independently)
ALTER TABLE data.applications
  ADD COLUMN IF NOT EXISTS candidate_visible_status text
  GENERATED ALWAYS AS (
    CASE WHEN outcome_communicated_at IS NOT NULL THEN 'closed' ELSE 'open' END
  ) STORED;

CREATE INDEX IF NOT EXISTS idx_applications_purge_at
  ON data.applications (purge_at)
  WHERE process_closed_at IS NULL OR purge_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_applications_posting
  ON data.applications (tenant_id, job_posting_id);

ALTER TABLE data.applications ENABLE ROW LEVEL SECURITY;

CREATE POLICY applications_select ON data.applications
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_has_recruitment_permission(tenant_id, 'recruitment.view')
  );

CREATE POLICY applications_write ON data.applications
  FOR ALL TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_has_recruitment_permission(tenant_id, 'recruitment.manage')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

-- ---------------------------------------------------------------------------
-- 7. consent events + erasure log
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.applicant_consent_events (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  applicant_id       uuid REFERENCES data.applicants(id) ON DELETE CASCADE,
  application_id     uuid REFERENCES data.applications(id) ON DELETE CASCADE,
  event_type         text NOT NULL,
  legal_text_version text,
  payload            jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at         timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE data.applicant_consent_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY applicant_consent_events_select ON data.applicant_consent_events
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      data.jwt_has_recruitment_permission(tenant_id, 'recruitment.view')
      OR data.jwt_has_recruitment_permission(tenant_id, 'recruitment.rights')
    )
  );

CREATE TABLE IF NOT EXISTS data.applicant_erasure_log (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  email_hmac   text NOT NULL,
  erased_at    timestamptz NOT NULL DEFAULT now(),
  reason       text NOT NULL
    CHECK (reason IN ('retention_policy', 'user_request', 'admin')),
  scope        text NOT NULL
    CHECK (scope IN ('application', 'applicant')),
  applications_count int
);

COMMENT ON TABLE data.applicant_erasure_log IS
  'REC-15: HMAC email is pseudonymised personal data, not anonymised.';

ALTER TABLE data.applicant_erasure_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY applicant_erasure_log_select ON data.applicant_erasure_log
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_has_recruitment_permission(tenant_id, 'recruitment.rights')
  );

-- ---------------------------------------------------------------------------
-- 8. purge_at recompute
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.compute_application_purge_at(
  p_tenant_id uuid,
  p_applied_at timestamptz,
  p_retention_preference text,
  p_retention_months int,
  p_process_closed_at timestamptz
)
RETURNS timestamptz
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_max int;
  v_ceiling timestamptz;
  v_pref timestamptz;
  v_close timestamptz := 'infinity'::timestamptz;
BEGIN
  SELECT default_max_retention_months INTO v_max
  FROM data.recruitment_settings
  WHERE tenant_id = p_tenant_id;

  IF v_max IS NULL THEN
    v_max := 12;
  END IF;

  v_ceiling := p_applied_at + make_interval(months => v_max);

  IF p_retention_preference = 'delete_after_months' THEN
    v_pref := p_applied_at + make_interval(months => LEAST(COALESCE(p_retention_months, v_max), v_max));
  ELSE
    v_pref := v_ceiling;
  END IF;

  IF p_retention_preference = 'delete_on_process_end' AND p_process_closed_at IS NOT NULL THEN
    v_close := p_process_closed_at;
  END IF;

  RETURN LEAST(v_pref, v_close, v_ceiling);
END;
$$;

CREATE OR REPLACE FUNCTION data.trg_applications_set_purge_at()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  NEW.purge_at := data.compute_application_purge_at(
    NEW.tenant_id,
    COALESCE(NEW.created_at, now()),
    NEW.retention_preference,
    NEW.retention_months,
    NEW.process_closed_at
  );
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_applications_set_purge_at ON data.applications;
CREATE TRIGGER trg_applications_set_purge_at
  BEFORE INSERT OR UPDATE OF retention_preference, retention_months, process_closed_at
  ON data.applications
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_applications_set_purge_at();

-- ---------------------------------------------------------------------------
-- 9. Purge cron job
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.applicant_email_hmac(p_tenant_id uuid, p_email text)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, data
AS $$
DECLARE
  v_key bytea;
BEGIN
  SELECT erasure_hmac_key INTO v_key
  FROM data.recruitment_settings
  WHERE tenant_id = p_tenant_id;

  IF v_key IS NULL THEN
    RAISE EXCEPTION 'recruitment_settings_missing';
  END IF;

  RETURN encode(
    hmac(convert_to(lower(trim(p_email)), 'UTF8'), v_key, 'sha256'),
    'hex'
  );
END;
$$;

CREATE OR REPLACE FUNCTION data.purge_expired_applications()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  r record;
  v_count int := 0;
  v_email text;
  v_hmac text;
  v_remain int;
BEGIN
  FOR r IN
    SELECT a.id, a.tenant_id, a.applicant_id, a.cv_storage_path
    FROM data.applications a
    WHERE a.purge_at <= now()
    ORDER BY a.purge_at
    LIMIT 500
  LOOP
    SELECT email INTO v_email FROM data.applicants WHERE id = r.applicant_id;
    v_hmac := data.applicant_email_hmac(r.tenant_id, v_email);

    DELETE FROM data.applicant_consent_events WHERE application_id = r.id;
    DELETE FROM data.applications WHERE id = r.id;

    INSERT INTO data.applicant_erasure_log (
      tenant_id, email_hmac, reason, scope, applications_count
    ) VALUES (
      r.tenant_id, v_hmac, 'retention_policy', 'application', 1
    );

    SELECT count(*) INTO v_remain
    FROM data.applications
    WHERE applicant_id = r.applicant_id;

    IF v_remain = 0 THEN
      IF NOT EXISTS (
        SELECT 1 FROM data.applicants ap
        WHERE ap.id = r.applicant_id
          AND ap.talent_pool_until IS NOT NULL
          AND ap.talent_pool_until > now()
      ) THEN
        DELETE FROM data.applicant_consent_events WHERE applicant_id = r.applicant_id;
        DELETE FROM data.applicants WHERE id = r.applicant_id;
        INSERT INTO data.applicant_erasure_log (
          tenant_id, email_hmac, reason, scope, applications_count
        ) VALUES (
          r.tenant_id, v_hmac, 'retention_policy', 'applicant', 0
        );
      END IF;
    END IF;

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    BEGIN
      PERFORM cron.unschedule('recruitment-purge-expired-applications');
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
    PERFORM cron.schedule(
      'recruitment-purge-expired-applications',
      '15 3 * * *',
      $cron$SELECT data.purge_expired_applications()$cron$
    );
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 10. Storage bucket
-- ---------------------------------------------------------------------------
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'recruitment-cvs',
  'recruitment-cvs',
  false,
  10485760,
  ARRAY['application/pdf', 'application/msword',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document']::text[]
)
ON CONFLICT (id) DO UPDATE SET
  public = EXCLUDED.public,
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

-- ---------------------------------------------------------------------------
-- 11. API views (security_invoker)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.recruitment_settings
WITH (security_invoker = true) AS
SELECT
  tenant_id,
  default_max_retention_months,
  expire_closes_process,
  rights_sla_days,
  rejection_notify_policy,
  privacy_policy_url,
  import_legal_basis,
  import_legal_basis_note,
  enforce_department_scope,
  analytics_min_cohort,
  created_at,
  updated_at
FROM data.recruitment_settings;

CREATE OR REPLACE VIEW api.job_postings
WITH (security_invoker = true) AS
SELECT * FROM data.job_postings;

CREATE OR REPLACE VIEW api.job_posting_public_sites
WITH (security_invoker = true) AS
SELECT * FROM data.job_posting_public_sites;

CREATE OR REPLACE VIEW api.job_posting_templates
WITH (security_invoker = true) AS
SELECT * FROM data.job_posting_templates;

CREATE OR REPLACE VIEW api.pipeline_stages
WITH (security_invoker = true) AS
SELECT * FROM data.pipeline_stages;

CREATE OR REPLACE VIEW api.applicants
WITH (security_invoker = true) AS
SELECT
  id, tenant_id, email, full_name, phone,
  email_verified_at, talent_pool_until, created_at, updated_at
FROM data.applicants;

CREATE OR REPLACE VIEW api.applications
WITH (security_invoker = true) AS
SELECT * FROM data.applications;

GRANT SELECT, UPDATE ON api.recruitment_settings TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.job_postings TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.job_posting_public_sites TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.job_posting_templates TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.pipeline_stages TO authenticated;
GRANT SELECT ON api.applicants TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.applications TO authenticated;

-- ---------------------------------------------------------------------------
-- 12. get_tenant_features + recruitment_enabled
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_tenant_features()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
BEGIN
  IF auth.uid() IS NULL OR v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN jsonb_build_object(
    'entity_timeline_risk_detector',
      data.is_feature_enabled(v_tenant_id, 'entity_timeline_risk_detector'),
    'entity_timeline_playbooks',
      data.is_feature_enabled(v_tenant_id, 'entity_timeline_playbooks'),
    'entity_timeline_webhooks',
      data.is_feature_enabled(v_tenant_id, 'entity_timeline_webhooks'),
    'entity_timeline_export',
      data.is_feature_enabled(v_tenant_id, 'entity_timeline_export'),
    'entity_timeline_manager_feed',
      data.is_feature_enabled(v_tenant_id, 'entity_timeline_manager_feed'),
    'recruitment_enabled',
      data.is_feature_enabled(v_tenant_id, 'recruitment_enabled')
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_tenant_features() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_tenant_features() TO authenticated;

NOTIFY pgrst, 'reload schema';
