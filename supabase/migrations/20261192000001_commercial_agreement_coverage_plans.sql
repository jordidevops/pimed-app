-- CF-21-b: agreement coverage + N:M with maintenance_plans (link only; no OS gate).
-- The maintenance plan still generates work orders; this link does not change the cron.

-- ---------------------------------------------------------------------------
-- Event types
-- ---------------------------------------------------------------------------
ALTER TABLE data.commercial_agreement_events
  DROP CONSTRAINT IF EXISTS commercial_agreement_events_event_type_check;

ALTER TABLE data.commercial_agreement_events
  ADD CONSTRAINT commercial_agreement_events_event_type_check
  CHECK (event_type IN (
    'created', 'prepared', 'sent', 'signed', 'activated',
    'cancelled', 'project_linked', 'project_unlinked',
    'suspended', 'finished',
    'coverage_linked', 'coverage_unlinked',
    'maintenance_plan_linked', 'maintenance_plan_unlinked'
  ));

-- ---------------------------------------------------------------------------
-- Coverage (what the agreement covers)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.commercial_agreement_coverage (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  agreement_id  uuid NOT NULL REFERENCES data.commercial_agreements(id) ON DELETE CASCADE,
  entity_type   text NOT NULL
                CHECK (entity_type = ANY (ARRAY['contact', 'contact_site', 'asset']::text[])),
  entity_id     uuid NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agreement_id, entity_type, entity_id)
);

CREATE INDEX IF NOT EXISTS idx_commercial_agreement_coverage_agreement
  ON data.commercial_agreement_coverage (agreement_id);

CREATE INDEX IF NOT EXISTS idx_commercial_agreement_coverage_entity
  ON data.commercial_agreement_coverage (tenant_id, entity_type, entity_id);

COMMENT ON TABLE data.commercial_agreement_coverage IS
  'CF-21-b: entitats cobertes per l''acord (client / seu / actiu). '
  'El pla de manteniment genera OS; aquest registre no canvia el cron ni el gate d''OS.';

-- ---------------------------------------------------------------------------
-- N:M agreement ↔ maintenance_plans
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.commercial_agreement_maintenance_plans (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id            uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  agreement_id         uuid NOT NULL REFERENCES data.commercial_agreements(id) ON DELETE CASCADE,
  maintenance_plan_id  uuid NOT NULL REFERENCES data.maintenance_plans(id) ON DELETE CASCADE,
  created_at           timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agreement_id, maintenance_plan_id)
);

CREATE INDEX IF NOT EXISTS idx_commercial_agreement_mp_plan
  ON data.commercial_agreement_maintenance_plans (maintenance_plan_id);

CREATE INDEX IF NOT EXISTS idx_commercial_agreement_mp_agreement
  ON data.commercial_agreement_maintenance_plans (agreement_id);

COMMENT ON TABLE data.commercial_agreement_maintenance_plans IS
  'CF-21-b: N:M acord comercial ↔ pla de manteniment. '
  'El pla continua generant OS; l''enllaç només declara inclusió comercial. Sense gate d''OS.';

-- ---------------------------------------------------------------------------
-- Same-tenant triggers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_commercial_agreement_coverage_same_tenant()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_tenant uuid;
BEGIN
  SELECT tenant_id INTO v_tenant FROM data.commercial_agreements WHERE id = NEW.agreement_id;
  IF v_tenant IS NULL OR v_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'agreement_coverage_tenant_mismatch' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_commercial_agreement_coverage_same_tenant
  ON data.commercial_agreement_coverage;
CREATE TRIGGER trg_commercial_agreement_coverage_same_tenant
  BEFORE INSERT OR UPDATE ON data.commercial_agreement_coverage
  FOR EACH ROW EXECUTE FUNCTION data.trg_commercial_agreement_coverage_same_tenant();

CREATE OR REPLACE FUNCTION data.trg_commercial_agreement_mp_same_tenant()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_agreement_tenant uuid;
  v_plan_tenant uuid;
BEGIN
  SELECT tenant_id INTO v_agreement_tenant
  FROM data.commercial_agreements WHERE id = NEW.agreement_id;
  IF v_agreement_tenant IS NULL OR v_agreement_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'agreement_plan_tenant_mismatch' USING ERRCODE = 'P0001';
  END IF;
  SELECT tenant_id INTO v_plan_tenant
  FROM data.maintenance_plans WHERE id = NEW.maintenance_plan_id;
  IF v_plan_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'agreement_plan_tenant_mismatch' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_commercial_agreement_mp_same_tenant
  ON data.commercial_agreement_maintenance_plans;
CREATE TRIGGER trg_commercial_agreement_mp_same_tenant
  BEFORE INSERT OR UPDATE ON data.commercial_agreement_maintenance_plans
  FOR EACH ROW EXECUTE FUNCTION data.trg_commercial_agreement_mp_same_tenant();

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
ALTER TABLE data.commercial_agreement_coverage ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.commercial_agreement_maintenance_plans ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS cac_select ON data.commercial_agreement_coverage;
CREATE POLICY cac_select ON data.commercial_agreement_coverage
  FOR SELECT TO authenticated
  USING (data.jwt_user_tenants() ? tenant_id::text);

DROP POLICY IF EXISTS camp_select ON data.commercial_agreement_maintenance_plans;
CREATE POLICY camp_select ON data.commercial_agreement_maintenance_plans
  FOR SELECT TO authenticated
  USING (data.jwt_user_tenants() ? tenant_id::text);

REVOKE ALL ON data.commercial_agreement_coverage FROM PUBLIC, anon, authenticated;
REVOKE ALL ON data.commercial_agreement_maintenance_plans FROM PUBLIC, anon, authenticated;

GRANT SELECT ON data.commercial_agreement_coverage TO authenticated;
GRANT SELECT ON data.commercial_agreement_maintenance_plans TO authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON data.commercial_agreement_coverage TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.commercial_agreement_maintenance_plans TO service_role;

CREATE OR REPLACE VIEW api.commercial_agreement_coverage
WITH (security_invoker = true) AS
SELECT * FROM data.commercial_agreement_coverage;

CREATE OR REPLACE VIEW api.commercial_agreement_maintenance_plans
WITH (security_invoker = true) AS
SELECT * FROM data.commercial_agreement_maintenance_plans;

GRANT SELECT ON api.commercial_agreement_coverage TO authenticated, service_role;
GRANT SELECT ON api.commercial_agreement_maintenance_plans TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.agreement_coverage_entity_belongs_to_client(
  p_tenant_id uuid,
  p_client_id uuid,
  p_entity_type text,
  p_entity_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_entity_type = 'contact' THEN
    RETURN EXISTS (
      SELECT 1 FROM data.contacts c
      WHERE c.id = p_entity_id
        AND c.tenant_id = p_tenant_id
        AND c.id = p_client_id
    );
  END IF;
  IF p_entity_type = 'contact_site' THEN
    RETURN EXISTS (
      SELECT 1 FROM data.contact_sites s
      WHERE s.id = p_entity_id
        AND s.tenant_id = p_tenant_id
        AND s.contact_id = p_client_id
    );
  END IF;
  IF p_entity_type = 'asset' THEN
    RETURN EXISTS (
      SELECT 1
      FROM data.assets a
      JOIN data.contact_sites s ON s.id = a.contact_site_id
      WHERE a.id = p_entity_id
        AND a.tenant_id = p_tenant_id
        AND s.contact_id = p_client_id
    );
  END IF;
  RETURN false;
END;
$$;

REVOKE ALL ON FUNCTION data.agreement_coverage_entity_belongs_to_client(uuid, uuid, text, uuid)
  FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- RPCs: coverage
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.link_agreement_coverage(
  p_agreement_id uuid,
  p_entity_type text,
  p_entity_id uuid,
  p_client_op_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_agreement data.commercial_agreements%ROWTYPE;
  v_event data.commercial_agreement_events%ROWTYPE;
  v_link_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_entity_type IS NULL OR p_entity_type NOT IN ('contact', 'contact_site', 'asset') THEN
    RAISE EXCEPTION 'invalid_coverage_entity_type' USING ERRCODE = 'P0001';
  END IF;
  IF p_entity_id IS NULL THEN
    RAISE EXCEPTION 'coverage_entity_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_agreement FROM data.commercial_agreements WHERE id = p_agreement_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_agreement.tenant_id::text) THEN
    RAISE EXCEPTION 'agreement_not_found' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_event
  FROM data.commercial_agreement_events
  WHERE tenant_id = v_agreement.tenant_id
    AND client_op_id = p_client_op_id;
  IF FOUND THEN
    IF v_event.event_type IS DISTINCT FROM 'coverage_linked'
       OR v_event.agreement_id IS DISTINCT FROM p_agreement_id THEN
      RAISE EXCEPTION 'client_op_conflict' USING ERRCODE = 'P0001';
    END IF;
    RETURN (v_event.payload->>'link_id')::uuid;
  END IF;

  IF COALESCE((
    SELECT tm.role FROM data.tenant_members tm
    WHERE tm.tenant_id = v_agreement.tenant_id
      AND tm.user_id = v_uid AND tm.site_id IS NULL
    LIMIT 1
  ), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'permission_denied:agreement_prepare' USING ERRCODE = 'P0001';
  END IF;

  IF v_agreement.status = 'cancelled' THEN
    RAISE EXCEPTION 'agreement_not_linkable' USING ERRCODE = 'P0001';
  END IF;

  IF NOT data.agreement_coverage_entity_belongs_to_client(
    v_agreement.tenant_id, v_agreement.client_id, p_entity_type, p_entity_id
  ) THEN
    RAISE EXCEPTION 'agreement_coverage_client_mismatch' USING ERRCODE = 'P0001';
  END IF;

  SELECT id INTO v_link_id
  FROM data.commercial_agreement_coverage
  WHERE agreement_id = p_agreement_id
    AND entity_type = p_entity_type
    AND entity_id = p_entity_id;
  IF v_link_id IS NOT NULL THEN
    RETURN v_link_id;
  END IF;

  INSERT INTO data.commercial_agreement_coverage (
    tenant_id, agreement_id, entity_type, entity_id
  ) VALUES (
    v_agreement.tenant_id, p_agreement_id, p_entity_type, p_entity_id
  ) RETURNING id INTO v_link_id;

  INSERT INTO data.commercial_agreement_events (
    tenant_id, agreement_id, event_type, actor_id, client_op_id, payload
  ) VALUES (
    v_agreement.tenant_id, p_agreement_id, 'coverage_linked', v_uid, p_client_op_id,
    jsonb_build_object(
      'entity_type', p_entity_type,
      'entity_id', p_entity_id,
      'link_id', v_link_id
    )
  );

  RETURN v_link_id;
END;
$$;

COMMENT ON FUNCTION api.link_agreement_coverage(uuid, text, uuid, uuid) IS
  'CF-21-b: vincula cobertura (contact/contact_site/asset del mateix client). Idempotent.';

REVOKE ALL ON FUNCTION api.link_agreement_coverage(uuid, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.link_agreement_coverage(uuid, text, uuid, uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.unlink_agreement_coverage(
  p_agreement_id uuid,
  p_entity_type text,
  p_entity_id uuid,
  p_client_op_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_agreement data.commercial_agreements%ROWTYPE;
  v_event data.commercial_agreement_events%ROWTYPE;
  v_link_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_agreement FROM data.commercial_agreements WHERE id = p_agreement_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_agreement.tenant_id::text) THEN
    RAISE EXCEPTION 'agreement_not_found' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_event
  FROM data.commercial_agreement_events
  WHERE tenant_id = v_agreement.tenant_id
    AND client_op_id = p_client_op_id;
  IF FOUND THEN
    IF v_event.event_type IS DISTINCT FROM 'coverage_unlinked'
       OR v_event.agreement_id IS DISTINCT FROM p_agreement_id THEN
      RAISE EXCEPTION 'client_op_conflict' USING ERRCODE = 'P0001';
    END IF;
    RETURN;
  END IF;

  IF COALESCE((
    SELECT tm.role FROM data.tenant_members tm
    WHERE tm.tenant_id = v_agreement.tenant_id
      AND tm.user_id = v_uid AND tm.site_id IS NULL
    LIMIT 1
  ), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'permission_denied:agreement_prepare' USING ERRCODE = 'P0001';
  END IF;

  SELECT id INTO v_link_id
  FROM data.commercial_agreement_coverage
  WHERE agreement_id = p_agreement_id
    AND entity_type = p_entity_type
    AND entity_id = p_entity_id;
  IF v_link_id IS NULL THEN
    RAISE EXCEPTION 'agreement_coverage_not_linked' USING ERRCODE = 'P0001';
  END IF;

  DELETE FROM data.commercial_agreement_coverage WHERE id = v_link_id;

  INSERT INTO data.commercial_agreement_events (
    tenant_id, agreement_id, event_type, actor_id, client_op_id, payload
  ) VALUES (
    v_agreement.tenant_id, p_agreement_id, 'coverage_unlinked', v_uid, p_client_op_id,
    jsonb_build_object(
      'entity_type', p_entity_type,
      'entity_id', p_entity_id,
      'link_id', v_link_id
    )
  );
END;
$$;

COMMENT ON FUNCTION api.unlink_agreement_coverage(uuid, text, uuid, uuid) IS
  'CF-21-b: desvincula cobertura i deixa event. No toca PDFs ni el pla de manteniment.';

REVOKE ALL ON FUNCTION api.unlink_agreement_coverage(uuid, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.unlink_agreement_coverage(uuid, text, uuid, uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- RPCs: maintenance plans
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.link_agreement_maintenance_plan(
  p_agreement_id uuid,
  p_maintenance_plan_id uuid,
  p_client_op_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_agreement data.commercial_agreements%ROWTYPE;
  v_plan data.maintenance_plans%ROWTYPE;
  v_event data.commercial_agreement_events%ROWTYPE;
  v_link_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_agreement FROM data.commercial_agreements WHERE id = p_agreement_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_agreement.tenant_id::text) THEN
    RAISE EXCEPTION 'agreement_not_found' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_event
  FROM data.commercial_agreement_events
  WHERE tenant_id = v_agreement.tenant_id
    AND client_op_id = p_client_op_id;
  IF FOUND THEN
    IF v_event.event_type IS DISTINCT FROM 'maintenance_plan_linked'
       OR v_event.agreement_id IS DISTINCT FROM p_agreement_id THEN
      RAISE EXCEPTION 'client_op_conflict' USING ERRCODE = 'P0001';
    END IF;
    RETURN (v_event.payload->>'link_id')::uuid;
  END IF;

  IF COALESCE((
    SELECT tm.role FROM data.tenant_members tm
    WHERE tm.tenant_id = v_agreement.tenant_id
      AND tm.user_id = v_uid AND tm.site_id IS NULL
    LIMIT 1
  ), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'permission_denied:agreement_prepare' USING ERRCODE = 'P0001';
  END IF;

  IF v_agreement.status = 'cancelled' THEN
    RAISE EXCEPTION 'agreement_not_linkable' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_plan FROM data.maintenance_plans WHERE id = p_maintenance_plan_id;
  IF NOT FOUND OR v_plan.tenant_id IS DISTINCT FROM v_agreement.tenant_id THEN
    RAISE EXCEPTION 'agreement_plan_tenant_mismatch' USING ERRCODE = 'P0001';
  END IF;

  SELECT id INTO v_link_id
  FROM data.commercial_agreement_maintenance_plans
  WHERE agreement_id = p_agreement_id
    AND maintenance_plan_id = p_maintenance_plan_id;
  IF v_link_id IS NOT NULL THEN
    RETURN v_link_id;
  END IF;

  INSERT INTO data.commercial_agreement_maintenance_plans (
    tenant_id, agreement_id, maintenance_plan_id
  ) VALUES (
    v_agreement.tenant_id, p_agreement_id, p_maintenance_plan_id
  ) RETURNING id INTO v_link_id;

  INSERT INTO data.commercial_agreement_events (
    tenant_id, agreement_id, event_type, actor_id, client_op_id, payload
  ) VALUES (
    v_agreement.tenant_id, p_agreement_id, 'maintenance_plan_linked', v_uid, p_client_op_id,
    jsonb_build_object(
      'maintenance_plan_id', p_maintenance_plan_id,
      'link_id', v_link_id
    )
  );

  RETURN v_link_id;
END;
$$;

COMMENT ON FUNCTION api.link_agreement_maintenance_plan(uuid, uuid, uuid) IS
  'CF-21-b: vincula un pla de manteniment del tenant a l''acord. No canvia el cron d''OS.';

REVOKE ALL ON FUNCTION api.link_agreement_maintenance_plan(uuid, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.link_agreement_maintenance_plan(uuid, uuid, uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.unlink_agreement_maintenance_plan(
  p_agreement_id uuid,
  p_maintenance_plan_id uuid,
  p_client_op_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_agreement data.commercial_agreements%ROWTYPE;
  v_event data.commercial_agreement_events%ROWTYPE;
  v_link_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_agreement FROM data.commercial_agreements WHERE id = p_agreement_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_agreement.tenant_id::text) THEN
    RAISE EXCEPTION 'agreement_not_found' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_event
  FROM data.commercial_agreement_events
  WHERE tenant_id = v_agreement.tenant_id
    AND client_op_id = p_client_op_id;
  IF FOUND THEN
    IF v_event.event_type IS DISTINCT FROM 'maintenance_plan_unlinked'
       OR v_event.agreement_id IS DISTINCT FROM p_agreement_id THEN
      RAISE EXCEPTION 'client_op_conflict' USING ERRCODE = 'P0001';
    END IF;
    RETURN;
  END IF;

  IF COALESCE((
    SELECT tm.role FROM data.tenant_members tm
    WHERE tm.tenant_id = v_agreement.tenant_id
      AND tm.user_id = v_uid AND tm.site_id IS NULL
    LIMIT 1
  ), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'permission_denied:agreement_prepare' USING ERRCODE = 'P0001';
  END IF;

  SELECT id INTO v_link_id
  FROM data.commercial_agreement_maintenance_plans
  WHERE agreement_id = p_agreement_id
    AND maintenance_plan_id = p_maintenance_plan_id;
  IF v_link_id IS NULL THEN
    RAISE EXCEPTION 'agreement_plan_not_linked' USING ERRCODE = 'P0001';
  END IF;

  DELETE FROM data.commercial_agreement_maintenance_plans WHERE id = v_link_id;

  INSERT INTO data.commercial_agreement_events (
    tenant_id, agreement_id, event_type, actor_id, client_op_id, payload
  ) VALUES (
    v_agreement.tenant_id, p_agreement_id, 'maintenance_plan_unlinked', v_uid, p_client_op_id,
    jsonb_build_object(
      'maintenance_plan_id', p_maintenance_plan_id,
      'link_id', v_link_id
    )
  );
END;
$$;

COMMENT ON FUNCTION api.unlink_agreement_maintenance_plan(uuid, uuid, uuid) IS
  'CF-21-b: desvincula el pla de l''acord i deixa event. No esborra el pla ni atura el cron.';

REVOKE ALL ON FUNCTION api.unlink_agreement_maintenance_plan(uuid, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.unlink_agreement_maintenance_plan(uuid, uuid, uuid)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
