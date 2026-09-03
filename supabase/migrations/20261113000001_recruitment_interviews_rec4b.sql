-- =============================================================================
-- REC-4b — Interviews + notes (no question sets / evaluations)
-- =============================================================================

INSERT INTO data.entity_types (
  code, label_key,
  supports_timeline, supports_documents, supports_signing, supports_subscriptions
)
SELECT v.code, v.label_key, v.tl, v.doc, v.sig, v.sub
FROM (
  VALUES
    ('interview', 'entity_types.interview', false, false, false, false)
) AS v(code, label_key, tl, doc, sig, sub)
WHERE NOT EXISTS (
  SELECT 1 FROM data.entity_types et WHERE et.code = v.code
);

CREATE TABLE IF NOT EXISTS data.interviews (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  application_id     uuid NOT NULL REFERENCES data.applications(id) ON DELETE CASCADE,
  job_posting_id     uuid NOT NULL REFERENCES data.job_postings(id) ON DELETE CASCADE,
  type               text NOT NULL
    CHECK (type IN ('phone', 'online', 'onsite')),
  scheduled_at       timestamptz,
  duration_minutes   int DEFAULT 60
    CHECK (duration_minutes IS NULL OR duration_minutes > 0),
  location_or_link   text,
  notes              text,
  status             text NOT NULL DEFAULT 'scheduled'
    CHECK (status IN ('scheduled', 'completed', 'cancelled', 'no_show')),
  created_by         uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_interviews_application
  ON data.interviews (tenant_id, application_id);

CREATE INDEX IF NOT EXISTS idx_interviews_scheduled
  ON data.interviews (tenant_id, scheduled_at);

-- Keep job_posting_id in sync with application
CREATE OR REPLACE FUNCTION data.trg_interviews_set_posting()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_app data.applications%ROWTYPE;
BEGIN
  SELECT * INTO v_app FROM data.applications WHERE id = NEW.application_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'application_not_found';
  END IF;
  IF NEW.tenant_id IS DISTINCT FROM v_app.tenant_id THEN
    RAISE EXCEPTION 'tenant_mismatch';
  END IF;
  NEW.job_posting_id := v_app.job_posting_id;
  NEW.updated_at := now();
  IF TG_OP = 'INSERT' AND NEW.created_by IS NULL THEN
    NEW.created_by := auth.uid();
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_interviews_set_posting ON data.interviews;
CREATE TRIGGER trg_interviews_set_posting
  BEFORE INSERT OR UPDATE OF application_id, tenant_id ON data.interviews
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_interviews_set_posting();

ALTER TABLE data.interviews ENABLE ROW LEVEL SECURITY;

CREATE POLICY interviews_select ON data.interviews
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      data.jwt_has_recruitment_permission(tenant_id, 'recruitment.view')
      OR data.jwt_has_recruitment_permission(tenant_id, 'recruitment.interview')
      OR data.jwt_has_recruitment_permission(tenant_id, 'recruitment.manage')
    )
  );

CREATE POLICY interviews_insert ON data.interviews
  FOR INSERT TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      data.jwt_has_recruitment_permission(tenant_id, 'recruitment.interview')
      OR data.jwt_has_recruitment_permission(tenant_id, 'recruitment.manage')
    )
  );

CREATE POLICY interviews_update ON data.interviews
  FOR UPDATE TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      data.jwt_has_recruitment_permission(tenant_id, 'recruitment.interview')
      OR data.jwt_has_recruitment_permission(tenant_id, 'recruitment.manage')
    )
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

CREATE POLICY interviews_delete ON data.interviews
  FOR DELETE TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      data.jwt_has_recruitment_permission(tenant_id, 'recruitment.interview')
      OR data.jwt_has_recruitment_permission(tenant_id, 'recruitment.manage')
    )
  );

CREATE OR REPLACE VIEW api.interviews
WITH (security_invoker = true) AS
SELECT * FROM data.interviews;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.interviews TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.interviews TO authenticated;

NOTIFY pgrst, 'reload schema';
