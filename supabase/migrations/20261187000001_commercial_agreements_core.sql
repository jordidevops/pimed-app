-- CT-2: commercial agreement core. No prepare/render/signature RPC.
-- V1 writes only kind = specific unless app.commercial_agreement_kind_unlocked = on
-- (CF-21/CF-22 will use the same CHECK without a later kind migration).

CREATE TABLE IF NOT EXISTS data.commercial_agreements (
  id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  client_id          uuid        NOT NULL REFERENCES data.contacts(id) ON DELETE RESTRICT,
  kind               text        NOT NULL
                     CHECK (kind IN ('specific', 'recurring', 'framework', 'project')),
  status             text        NOT NULL DEFAULT 'pending_start'
                     CHECK (status IN (
                       'pending_start', 'active', 'suspended', 'cancelled', 'finished'
                     )),
  active_version_id  uuid,
  source_quote_id    uuid        NOT NULL REFERENCES data.commercial_documents(id) ON DELETE RESTRICT,
  work_gate          text        NOT NULL DEFAULT 'none'
                     CHECK (work_gate IN ('none', 'require_signed_agreement')),
  created_by         uuid        REFERENCES data.profiles(id) ON DELETE SET NULL,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_commercial_agreements_tenant_client
  ON data.commercial_agreements (tenant_id, client_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_commercial_agreements_source_quote
  ON data.commercial_agreements (source_quote_id);

CREATE INDEX IF NOT EXISTS idx_commercial_agreements_status
  ON data.commercial_agreements (tenant_id, status);

COMMENT ON TABLE data.commercial_agreements IS
  'Identitat i cicle d''un acord comercial. El text firmat viu a les versions. V1 només crea kind=specific.';

COMMENT ON COLUMN data.commercial_agreements.kind IS
  'specific | recurring | framework | project. El CHECK ja admet els quatre. L''API V1 rebutja qualsevol valor diferent de specific.';

COMMENT ON COLUMN data.commercial_agreements.source_quote_id IS
  'Quote o ampliació que origina l''acord. NOT NULL a V1; CF-21 el farà opcional.';

CREATE TABLE IF NOT EXISTS data.commercial_agreement_versions (
  id                         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                  uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  agreement_id               uuid        NOT NULL REFERENCES data.commercial_agreements(id) ON DELETE CASCADE,
  version_no                 integer     NOT NULL CHECK (version_no > 0),
  status                     text        NOT NULL DEFAULT 'draft'
                             CHECK (status IN ('draft', 'pending_signature', 'signed')),
  source_quote_id            uuid        NOT NULL REFERENCES data.commercial_documents(id) ON DELETE RESTRICT,
  source_quote_content_hash  text,
  source_quote_document_id   uuid        REFERENCES data.documents(id) ON DELETE SET NULL,
  full_body_template_id      uuid        REFERENCES data.document_templates(id) ON DELETE RESTRICT,
  rendered_document_id       uuid        REFERENCES data.documents(id) ON DELETE SET NULL,
  signed_document_id         uuid        REFERENCES data.documents(id) ON DELETE SET NULL,
  content_hash               text,
  starts_on                  date,
  ends_on                    date,
  terms_snapshot             jsonb,
  created_at                 timestamptz NOT NULL DEFAULT now(),
  updated_at                 timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agreement_id, version_no)
);

CREATE INDEX IF NOT EXISTS idx_commercial_agreement_versions_agreement
  ON data.commercial_agreement_versions (agreement_id, version_no DESC);

COMMENT ON TABLE data.commercial_agreement_versions IS
  'Condicions de l''acord. Immutables quan l''estat és pending_signature o signed.';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'commercial_agreements_active_version_id_fkey'
  ) THEN
    ALTER TABLE data.commercial_agreements
      ADD CONSTRAINT commercial_agreements_active_version_id_fkey
      FOREIGN KEY (active_version_id)
      REFERENCES data.commercial_agreement_versions(id)
      ON DELETE SET NULL
      DEFERRABLE INITIALLY DEFERRED;
  END IF;
END;
$$;

CREATE TABLE IF NOT EXISTS data.commercial_agreement_events (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  agreement_id  uuid        NOT NULL REFERENCES data.commercial_agreements(id) ON DELETE CASCADE,
  event_type    text        NOT NULL
                CHECK (event_type IN (
                  'created', 'prepared', 'sent', 'signed', 'activated',
                  'cancelled', 'project_linked', 'project_unlinked',
                  'suspended', 'finished'
                )),
  actor_id      uuid        REFERENCES data.profiles(id) ON DELETE SET NULL,
  occurred_at   timestamptz NOT NULL DEFAULT now(),
  client_op_id  uuid,
  payload       jsonb       NOT NULL DEFAULT '{}'::jsonb,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_commercial_agreement_events_client_op
  ON data.commercial_agreement_events (tenant_id, client_op_id)
  WHERE client_op_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_commercial_agreement_events_agreement
  ON data.commercial_agreement_events (agreement_id, occurred_at DESC);

COMMENT ON TABLE data.commercial_agreement_events IS
  'Historial append-only de l''acord. No s''actualitza ni s''esborra.';

CREATE TABLE IF NOT EXISTS data.commercial_agreement_projects (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  agreement_id  uuid        NOT NULL REFERENCES data.commercial_agreements(id) ON DELETE CASCADE,
  project_id    uuid        NOT NULL REFERENCES data.projects(id) ON DELETE CASCADE,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agreement_id, project_id)
);

CREATE INDEX IF NOT EXISTS idx_commercial_agreement_projects_project
  ON data.commercial_agreement_projects (project_id);

COMMENT ON TABLE data.commercial_agreement_projects IS
  'N:M acord-projecte. Desvincular (CT-4) no esborra PDFs.';

CREATE OR REPLACE FUNCTION data.trg_commercial_agreements_v1_kind()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.kind IS DISTINCT FROM 'specific'
     AND current_setting('app.commercial_agreement_kind_unlocked', true) IS DISTINCT FROM 'on' THEN
    RAISE EXCEPTION 'agreement_kind_not_in_v1'
      USING ERRCODE = 'P0001',
            HINT = 'V1 només crea acords specific. recurring, framework i project queden per CF-21/CF-22.';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_commercial_agreements_v1_kind ON data.commercial_agreements;
CREATE TRIGGER trg_commercial_agreements_v1_kind
  BEFORE INSERT OR UPDATE OF kind ON data.commercial_agreements
  FOR EACH ROW EXECUTE FUNCTION data.trg_commercial_agreements_v1_kind();

CREATE OR REPLACE FUNCTION data.trg_commercial_agreement_versions_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.status IN ('pending_signature', 'signed') THEN
    IF NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
       OR NEW.agreement_id IS DISTINCT FROM OLD.agreement_id
       OR NEW.version_no IS DISTINCT FROM OLD.version_no
       OR NEW.source_quote_id IS DISTINCT FROM OLD.source_quote_id
       OR NEW.source_quote_content_hash IS DISTINCT FROM OLD.source_quote_content_hash
       OR NEW.source_quote_document_id IS DISTINCT FROM OLD.source_quote_document_id
       OR NEW.full_body_template_id IS DISTINCT FROM OLD.full_body_template_id
       OR NEW.rendered_document_id IS DISTINCT FROM OLD.rendered_document_id
       OR NEW.signed_document_id IS DISTINCT FROM OLD.signed_document_id
       OR NEW.content_hash IS DISTINCT FROM OLD.content_hash
       OR NEW.starts_on IS DISTINCT FROM OLD.starts_on
       OR NEW.ends_on IS DISTINCT FROM OLD.ends_on
       OR NEW.terms_snapshot IS DISTINCT FROM OLD.terms_snapshot
       OR (
         NEW.status IS DISTINCT FROM OLD.status
         AND NOT (OLD.status = 'pending_signature' AND NEW.status = 'signed')
       )
    THEN
      RAISE EXCEPTION 'agreement_version_immutable'
        USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_commercial_agreement_versions_immutable ON data.commercial_agreement_versions;
CREATE TRIGGER trg_commercial_agreement_versions_immutable
  BEFORE UPDATE ON data.commercial_agreement_versions
  FOR EACH ROW EXECUTE FUNCTION data.trg_commercial_agreement_versions_immutable();

CREATE OR REPLACE FUNCTION data.trg_commercial_agreement_versions_same_tenant()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_agreement_tenant uuid;
  v_quote_tenant uuid;
BEGIN
  SELECT tenant_id INTO v_agreement_tenant
  FROM data.commercial_agreements
  WHERE id = NEW.agreement_id;

  SELECT tenant_id INTO v_quote_tenant
  FROM data.commercial_documents
  WHERE id = NEW.source_quote_id;

  IF v_agreement_tenant IS DISTINCT FROM NEW.tenant_id
     OR v_quote_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'agreement_version_tenant_mismatch'
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_commercial_agreement_versions_same_tenant ON data.commercial_agreement_versions;
CREATE TRIGGER trg_commercial_agreement_versions_same_tenant
  BEFORE INSERT OR UPDATE ON data.commercial_agreement_versions
  FOR EACH ROW EXECUTE FUNCTION data.trg_commercial_agreement_versions_same_tenant();

CREATE OR REPLACE FUNCTION data.trg_commercial_agreements_same_tenant()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_client_tenant uuid;
  v_quote_tenant uuid;
BEGIN
  SELECT tenant_id INTO v_client_tenant FROM data.contacts WHERE id = NEW.client_id;
  SELECT tenant_id INTO v_quote_tenant FROM data.commercial_documents WHERE id = NEW.source_quote_id;
  IF v_client_tenant IS DISTINCT FROM NEW.tenant_id
     OR v_quote_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'agreement_tenant_mismatch'
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_commercial_agreements_same_tenant ON data.commercial_agreements;
CREATE TRIGGER trg_commercial_agreements_same_tenant
  BEFORE INSERT OR UPDATE ON data.commercial_agreements
  FOR EACH ROW EXECUTE FUNCTION data.trg_commercial_agreements_same_tenant();

CREATE OR REPLACE FUNCTION data.trg_commercial_agreement_events_append_only()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'agreement_event_immutable'
    USING ERRCODE = 'P0001';
END;
$$;

DROP TRIGGER IF EXISTS trg_commercial_agreement_events_append_only ON data.commercial_agreement_events;
CREATE TRIGGER trg_commercial_agreement_events_append_only
  BEFORE UPDATE OR DELETE ON data.commercial_agreement_events
  FOR EACH ROW EXECUTE FUNCTION data.trg_commercial_agreement_events_append_only();

CREATE OR REPLACE FUNCTION data.trg_commercial_agreement_projects_same_tenant()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_agreement_tenant uuid;
  v_project_tenant uuid;
BEGIN
  SELECT tenant_id INTO v_agreement_tenant
  FROM data.commercial_agreements
  WHERE id = NEW.agreement_id;
  SELECT tenant_id INTO v_project_tenant
  FROM data.projects
  WHERE id = NEW.project_id;
  IF v_agreement_tenant IS DISTINCT FROM NEW.tenant_id
     OR v_project_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'agreement_project_tenant_mismatch'
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_commercial_agreement_projects_same_tenant ON data.commercial_agreement_projects;
CREATE TRIGGER trg_commercial_agreement_projects_same_tenant
  BEFORE INSERT OR UPDATE ON data.commercial_agreement_projects
  FOR EACH ROW EXECUTE FUNCTION data.trg_commercial_agreement_projects_same_tenant();

DROP TRIGGER IF EXISTS trg_commercial_agreements_updated_at ON data.commercial_agreements;
CREATE TRIGGER trg_commercial_agreements_updated_at
  BEFORE UPDATE ON data.commercial_agreements
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

DROP TRIGGER IF EXISTS trg_commercial_agreement_versions_updated_at ON data.commercial_agreement_versions;
CREATE TRIGGER trg_commercial_agreement_versions_updated_at
  BEFORE UPDATE ON data.commercial_agreement_versions
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

ALTER TABLE data.commercial_agreements ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.commercial_agreement_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.commercial_agreement_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.commercial_agreement_projects ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ca_select ON data.commercial_agreements;
CREATE POLICY ca_select ON data.commercial_agreements
  FOR SELECT TO authenticated
  USING (data.jwt_user_tenants() ? tenant_id::text);

DROP POLICY IF EXISTS cav_select ON data.commercial_agreement_versions;
CREATE POLICY cav_select ON data.commercial_agreement_versions
  FOR SELECT TO authenticated
  USING (data.jwt_user_tenants() ? tenant_id::text);

DROP POLICY IF EXISTS cae_select ON data.commercial_agreement_events;
CREATE POLICY cae_select ON data.commercial_agreement_events
  FOR SELECT TO authenticated
  USING (data.jwt_user_tenants() ? tenant_id::text);

DROP POLICY IF EXISTS cap_select ON data.commercial_agreement_projects;
CREATE POLICY cap_select ON data.commercial_agreement_projects
  FOR SELECT TO authenticated
  USING (data.jwt_user_tenants() ? tenant_id::text);

REVOKE ALL ON data.commercial_agreements FROM PUBLIC, anon, authenticated;
REVOKE ALL ON data.commercial_agreement_versions FROM PUBLIC, anon, authenticated;
REVOKE ALL ON data.commercial_agreement_events FROM PUBLIC, anon, authenticated;
REVOKE ALL ON data.commercial_agreement_projects FROM PUBLIC, anon, authenticated;

GRANT SELECT ON data.commercial_agreements TO authenticated;
GRANT SELECT ON data.commercial_agreement_versions TO authenticated;
GRANT SELECT ON data.commercial_agreement_events TO authenticated;
GRANT SELECT ON data.commercial_agreement_projects TO authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON data.commercial_agreements TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.commercial_agreement_versions TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.commercial_agreement_events TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.commercial_agreement_projects TO service_role;

CREATE OR REPLACE VIEW api.commercial_agreements
  WITH (security_invoker = true) AS
SELECT * FROM data.commercial_agreements
WHERE tenant_id = data.active_tenant_id();

CREATE OR REPLACE VIEW api.commercial_agreement_versions
  WITH (security_invoker = true) AS
SELECT * FROM data.commercial_agreement_versions
WHERE tenant_id = data.active_tenant_id();

CREATE OR REPLACE VIEW api.commercial_agreement_events
  WITH (security_invoker = true) AS
SELECT * FROM data.commercial_agreement_events
WHERE tenant_id = data.active_tenant_id();

CREATE OR REPLACE VIEW api.commercial_agreement_projects
  WITH (security_invoker = true) AS
SELECT * FROM data.commercial_agreement_projects
WHERE tenant_id = data.active_tenant_id();

GRANT SELECT ON api.commercial_agreements TO authenticated, service_role;
GRANT SELECT ON api.commercial_agreement_versions TO authenticated, service_role;
GRANT SELECT ON api.commercial_agreement_events TO authenticated, service_role;
GRANT SELECT ON api.commercial_agreement_projects TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
