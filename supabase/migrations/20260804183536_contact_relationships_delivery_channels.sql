-- =============================================================================
-- Migration: contact_relationships + contact_delivery_channels + delivery_rules
-- CP-A0.1 / CP-C rewrite — company↔person affiliation, contact points, delivery rules
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. ENUM role (commercial labels only — NOT ACL; no 'portal')
-- ---------------------------------------------------------------------------
DO $$ BEGIN
  CREATE TYPE data.contact_relationship_role AS ENUM (
    'primary',
    'billing',
    'operations',
    'other'
  );
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

-- ---------------------------------------------------------------------------
-- 2. DDL: contact_relationships
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.contact_relationships (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  organization_contact_id  uuid NOT NULL REFERENCES data.contacts(id) ON DELETE RESTRICT,
  person_contact_id        uuid NOT NULL REFERENCES data.contacts(id) ON DELETE RESTRICT,
  role                     data.contact_relationship_role NOT NULL DEFAULT 'other',
  starts_at                timestamptz NOT NULL DEFAULT now(),
  ends_at                  timestamptz,
  revoked_at               timestamptz,
  revoked_by               uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  revoke_reason            text,
  source                   text NOT NULL DEFAULT 'manual',
  created_by               uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT contact_relationships_distinct_parties
    CHECK (organization_contact_id <> person_contact_id),
  CONSTRAINT contact_relationships_ends_after_start
    CHECK (ends_at IS NULL OR ends_at >= starts_at),
  CONSTRAINT contact_relationships_revoke_sets_end
    CHECK (revoked_at IS NULL OR ends_at IS NOT NULL)
);

-- One open-ended (no ends_at) non-revoked pair. Rows with a scheduled ends_at are
-- additionally gated by trg_contact_relationship_no_overlap_live (cannot use now()
-- in a partial unique index).
CREATE UNIQUE INDEX IF NOT EXISTS uq_contact_relationships_active
  ON data.contact_relationships (tenant_id, organization_contact_id, person_contact_id)
  WHERE revoked_at IS NULL AND ends_at IS NULL;

-- Live = not revoked, started, and not past ends_at (same predicate as invites/grants).
CREATE OR REPLACE FUNCTION data.contact_relationship_is_live(
  p_revoked_at timestamptz,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_at timestamptz DEFAULT now()
)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT p_revoked_at IS NULL
    AND p_starts_at <= p_at
    AND (p_ends_at IS NULL OR p_ends_at > p_at);
$$;

REVOKE ALL ON FUNCTION data.contact_relationship_is_live(timestamptz, timestamptz, timestamptz, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.contact_relationship_is_live(timestamptz, timestamptz, timestamptz, timestamptz)
  TO authenticated, service_role;

-- Block a second live affiliation for the same org↔person (incl. future ends_at).
CREATE OR REPLACE FUNCTION data.trg_contact_relationship_no_overlap_live()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = data
AS $$
BEGIN
  IF NOT data.contact_relationship_is_live(NEW.revoked_at, NEW.starts_at, NEW.ends_at, now()) THEN
    RETURN NEW;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM data.contact_relationships r
    WHERE r.tenant_id = NEW.tenant_id
      AND r.organization_contact_id = NEW.organization_contact_id
      AND r.person_contact_id = NEW.person_contact_id
      AND r.id IS DISTINCT FROM NEW.id
      AND data.contact_relationship_is_live(r.revoked_at, r.starts_at, r.ends_at, now())
  ) THEN
    RAISE EXCEPTION 'contact_relationship_already_active'
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_contact_relationship_no_overlap_live ON data.contact_relationships;
CREATE TRIGGER trg_contact_relationship_no_overlap_live
  BEFORE INSERT OR UPDATE OF revoked_at, starts_at, ends_at,
    organization_contact_id, person_contact_id, tenant_id
  ON data.contact_relationships
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_contact_relationship_no_overlap_live();

CREATE INDEX IF NOT EXISTS idx_contact_relationships_tenant
  ON data.contact_relationships (tenant_id);

CREATE INDEX IF NOT EXISTS idx_contact_relationships_org
  ON data.contact_relationships (tenant_id, organization_contact_id)
  WHERE revoked_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_contact_relationships_person
  ON data.contact_relationships (tenant_id, person_contact_id)
  WHERE revoked_at IS NULL;

COMMENT ON TABLE data.contact_relationships IS
  'CP-C: company↔person affiliation. Role is commercial metadata (primary/billing/'
  'operations/other), not ACL. Offboarding = revoke (no DELETE). '
  'Distinct from primary_contact_id (tutor/parent company).';

CREATE TRIGGER trg_contact_relationships_updated_at
  BEFORE UPDATE ON data.contact_relationships
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

-- ---------------------------------------------------------------------------
-- 3. DDL: contact_delivery_channels (contact points — company OR person)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.contact_delivery_channels (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id            uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  contact_id           uuid NOT NULL REFERENCES data.contacts(id) ON DELETE RESTRICT,
  channel_type         text NOT NULL CHECK (channel_type IN ('email', 'phone')),
  value_raw            text NOT NULL,
  value_normalized     text NOT NULL,
  verified_at          timestamptz,
  verification_method  text,
  disabled_at          timestamptz,
  disabled_by          uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  disable_reason       text,
  created_by           uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT contact_delivery_channels_verified_method
    CHECK (verified_at IS NULL OR verification_method IS NOT NULL)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_contact_delivery_channels_active
  ON data.contact_delivery_channels (tenant_id, contact_id, channel_type, value_normalized)
  WHERE disabled_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_contact_delivery_channels_contact
  ON data.contact_delivery_channels (tenant_id, contact_id)
  WHERE disabled_at IS NULL;

COMMENT ON TABLE data.contact_delivery_channels IS
  'CP-C: verifiable contact points (email/phone) on any contact (company or person). '
  'contacts.email/phone are CRM-only and do not count as verified.';

CREATE TRIGGER trg_contact_delivery_channels_updated_at
  BEFORE UPDATE ON data.contact_delivery_channels
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

-- ---------------------------------------------------------------------------
-- 4. DDL: contact_delivery_rules (purpose/policy per account + contact point)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.contact_delivery_rules (
  id                         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                  uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  client_account_contact_id  uuid NOT NULL REFERENCES data.contacts(id) ON DELETE RESTRICT,
  contact_point_id           uuid NOT NULL REFERENCES data.contact_delivery_channels(id) ON DELETE RESTRICT,
  purpose                    text NOT NULL CHECK (purpose IN ('bulletin', 'invoice')),
  policy                     text NOT NULL DEFAULT 'manual'
    CHECK (policy IN ('manual', 'on_publish')),
  disabled_at                timestamptz,
  disabled_by                uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  disable_reason             text,
  created_by                 uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  created_at                 timestamptz NOT NULL DEFAULT now(),
  updated_at                 timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_contact_delivery_rules_active
  ON data.contact_delivery_rules (
    tenant_id, client_account_contact_id, contact_point_id, purpose
  )
  WHERE disabled_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_contact_delivery_rules_account
  ON data.contact_delivery_rules (tenant_id, client_account_contact_id)
  WHERE disabled_at IS NULL;

COMMENT ON TABLE data.contact_delivery_rules IS
  'CP-C: delivery purpose/policy for a contact point under a client account. '
  'Roles on relationships are NOT ACL; this table owns bulletin/invoice delivery intent.';

CREATE TRIGGER trg_contact_delivery_rules_updated_at
  BEFORE UPDATE ON data.contact_delivery_rules
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

-- ---------------------------------------------------------------------------
-- 5. Validation triggers (kind + same tenant)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_validate_contact_relationship()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_org_kind   data.contact_kind;
  v_org_tenant uuid;
  v_per_kind   data.contact_kind;
  v_per_tenant uuid;
BEGIN
  SELECT kind, tenant_id INTO v_org_kind, v_org_tenant
  FROM data.contacts WHERE id = NEW.organization_contact_id;

  SELECT kind, tenant_id INTO v_per_kind, v_per_tenant
  FROM data.contacts WHERE id = NEW.person_contact_id;

  IF v_org_kind IS NULL OR v_per_kind IS NULL THEN
    RAISE EXCEPTION 'contact_relationship_contact_not_found'
      USING ERRCODE = 'P0001';
  END IF;

  IF v_org_tenant <> NEW.tenant_id OR v_per_tenant <> NEW.tenant_id THEN
    RAISE EXCEPTION 'contact_relationship_cross_tenant'
      USING ERRCODE = 'P0001';
  END IF;

  IF v_org_kind <> 'company' THEN
    RAISE EXCEPTION 'contact_relationship_org_must_be_company'
      USING ERRCODE = 'P0001';
  END IF;

  IF v_per_kind <> 'person' THEN
    RAISE EXCEPTION 'contact_relationship_person_must_be_person'
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_contact_relationship ON data.contact_relationships;
CREATE TRIGGER trg_validate_contact_relationship
  BEFORE INSERT OR UPDATE OF organization_contact_id, person_contact_id, tenant_id
  ON data.contact_relationships
  FOR EACH ROW EXECUTE FUNCTION data.trg_validate_contact_relationship();

CREATE OR REPLACE FUNCTION data.trg_validate_contact_delivery_channel()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_kind   data.contact_kind;
  v_tenant uuid;
BEGIN
  SELECT kind, tenant_id INTO v_kind, v_tenant
  FROM data.contacts WHERE id = NEW.contact_id;

  IF v_kind IS NULL THEN
    RAISE EXCEPTION 'contact_delivery_channel_contact_not_found'
      USING ERRCODE = 'P0001';
  END IF;

  IF v_tenant <> NEW.tenant_id THEN
    RAISE EXCEPTION 'contact_delivery_channel_cross_tenant'
      USING ERRCODE = 'P0001';
  END IF;

  -- CP-C: company OR person may own contact points (shared mailbox / person email)
  IF v_kind NOT IN ('company', 'person') THEN
    RAISE EXCEPTION 'contact_delivery_channel_invalid_kind'
      USING ERRCODE = 'P0001';
  END IF;

  NEW.value_normalized := CASE NEW.channel_type
    WHEN 'email' THEN lower(btrim(NEW.value_raw))
    WHEN 'phone' THEN regexp_replace(btrim(NEW.value_raw), '[^0-9+]', '', 'g')
    ELSE btrim(NEW.value_raw)
  END;

  IF NEW.value_normalized IS NULL OR NEW.value_normalized = '' THEN
    RAISE EXCEPTION 'contact_delivery_channel_empty_value'
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_contact_delivery_channel ON data.contact_delivery_channels;
CREATE TRIGGER trg_validate_contact_delivery_channel
  BEFORE INSERT OR UPDATE OF contact_id, tenant_id, channel_type, value_raw
  ON data.contact_delivery_channels
  FOR EACH ROW EXECUTE FUNCTION data.trg_validate_contact_delivery_channel();

CREATE OR REPLACE FUNCTION data.trg_validate_contact_delivery_rule()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_account_tenant uuid;
  v_account_kind   data.contact_kind;
  v_channel        data.contact_delivery_channels%ROWTYPE;
  v_point_contact  uuid;
BEGIN
  SELECT tenant_id, kind INTO v_account_tenant, v_account_kind
  FROM data.contacts WHERE id = NEW.client_account_contact_id;

  IF v_account_tenant IS NULL THEN
    RAISE EXCEPTION 'contact_delivery_rule_account_not_found'
      USING ERRCODE = 'P0001';
  END IF;

  IF v_account_tenant <> NEW.tenant_id THEN
    RAISE EXCEPTION 'contact_delivery_rule_cross_tenant'
      USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_channel
  FROM data.contact_delivery_channels
  WHERE id = NEW.contact_point_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'contact_delivery_rule_channel_not_found'
      USING ERRCODE = 'P0001';
  END IF;

  IF v_channel.tenant_id <> NEW.tenant_id THEN
    RAISE EXCEPTION 'contact_delivery_rule_channel_cross_tenant'
      USING ERRCODE = 'P0001';
  END IF;

  IF v_channel.disabled_at IS NOT NULL THEN
    RAISE EXCEPTION 'contact_delivery_rule_channel_disabled'
      USING ERRCODE = 'P0001';
  END IF;

  v_point_contact := v_channel.contact_id;

  -- Channel owner is the account itself, OR (when account is company) a related person
  IF v_point_contact = NEW.client_account_contact_id THEN
    RETURN NEW;
  END IF;

  IF v_account_kind = 'company' THEN
    IF EXISTS (
      SELECT 1 FROM data.contact_relationships r
      WHERE r.tenant_id = NEW.tenant_id
        AND r.organization_contact_id = NEW.client_account_contact_id
        AND r.person_contact_id = v_point_contact
        AND data.contact_relationship_is_live(r.revoked_at, r.starts_at, r.ends_at, now())
    ) THEN
      RETURN NEW;
    END IF;
  END IF;

  RAISE EXCEPTION 'contact_delivery_rule_contact_not_related'
    USING ERRCODE = 'P0001';
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_contact_delivery_rule ON data.contact_delivery_rules;
CREATE TRIGGER trg_validate_contact_delivery_rule
  BEFORE INSERT OR UPDATE OF tenant_id, client_account_contact_id, contact_point_id
  ON data.contact_delivery_rules
  FOR EACH ROW EXECUTE FUNCTION data.trg_validate_contact_delivery_rule();

-- ---------------------------------------------------------------------------
-- 6. Audit
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_audit_contact_relationships()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id, COALESCE(auth.uid(), NEW.created_by), NULL,
      'CONTACT_RELATIONSHIP_CREATED', 'contact_relationship', NEW.id,
      jsonb_build_object(
        'organization_contact_id', NEW.organization_contact_id,
        'person_contact_id', NEW.person_contact_id,
        'role', NEW.role
      )
    );
  ELSIF TG_OP = 'UPDATE' THEN
    IF OLD.revoked_at IS NULL AND NEW.revoked_at IS NOT NULL THEN
      PERFORM data.log_audit_event(
        NEW.tenant_id, auth.uid(), NULL,
        'CONTACT_RELATIONSHIP_REVOKED', 'contact_relationship', NEW.id,
        jsonb_build_object(
          'organization_contact_id', NEW.organization_contact_id,
          'person_contact_id', NEW.person_contact_id,
          'role', NEW.role,
          'revoke_reason', NEW.revoke_reason
        )
      );
    ELSE
      PERFORM data.log_audit_event(
        NEW.tenant_id, auth.uid(), NULL,
        'CONTACT_RELATIONSHIP_UPDATED', 'contact_relationship', NEW.id,
        jsonb_build_object(
          'organization_contact_id', NEW.organization_contact_id,
          'person_contact_id', NEW.person_contact_id,
          'role', NEW.role
        )
      );
    END IF;
  END IF;
  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_contact_relationships ON data.contact_relationships;
CREATE TRIGGER trg_audit_contact_relationships
  AFTER INSERT OR UPDATE ON data.contact_relationships
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_contact_relationships();

CREATE OR REPLACE FUNCTION data.trg_audit_contact_delivery_channels()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id, COALESCE(auth.uid(), NEW.created_by), NULL,
      'CONTACT_DELIVERY_CHANNEL_CREATED', 'contact_delivery_channel', NEW.id,
      jsonb_build_object(
        'contact_id', NEW.contact_id,
        'channel_type', NEW.channel_type,
        'verified', NEW.verified_at IS NOT NULL
      )
    );
  ELSIF TG_OP = 'UPDATE' THEN
    IF OLD.disabled_at IS NULL AND NEW.disabled_at IS NOT NULL THEN
      PERFORM data.log_audit_event(
        NEW.tenant_id, auth.uid(), NULL,
        'CONTACT_DELIVERY_CHANNEL_DISABLED', 'contact_delivery_channel', NEW.id,
        jsonb_build_object(
          'contact_id', NEW.contact_id,
          'channel_type', NEW.channel_type,
          'disable_reason', NEW.disable_reason
        )
      );
    ELSIF OLD.verified_at IS NULL AND NEW.verified_at IS NOT NULL THEN
      PERFORM data.log_audit_event(
        NEW.tenant_id, auth.uid(), NULL,
        'CONTACT_DELIVERY_CHANNEL_VERIFIED', 'contact_delivery_channel', NEW.id,
        jsonb_build_object(
          'contact_id', NEW.contact_id,
          'channel_type', NEW.channel_type,
          'verification_method', NEW.verification_method
        )
      );
    ELSE
      PERFORM data.log_audit_event(
        NEW.tenant_id, auth.uid(), NULL,
        'CONTACT_DELIVERY_CHANNEL_UPDATED', 'contact_delivery_channel', NEW.id,
        jsonb_build_object(
          'contact_id', NEW.contact_id,
          'channel_type', NEW.channel_type
        )
      );
    END IF;
  END IF;
  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_contact_delivery_channels ON data.contact_delivery_channels;
CREATE TRIGGER trg_audit_contact_delivery_channels
  AFTER INSERT OR UPDATE ON data.contact_delivery_channels
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_contact_delivery_channels();

CREATE OR REPLACE FUNCTION data.trg_audit_contact_delivery_rules()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id, COALESCE(auth.uid(), NEW.created_by), NULL,
      'CONTACT_DELIVERY_RULE_CREATED', 'contact_delivery_rule', NEW.id,
      jsonb_build_object(
        'client_account_contact_id', NEW.client_account_contact_id,
        'contact_point_id', NEW.contact_point_id,
        'purpose', NEW.purpose,
        'policy', NEW.policy
      )
    );
  ELSIF TG_OP = 'UPDATE' THEN
    IF OLD.disabled_at IS NULL AND NEW.disabled_at IS NOT NULL THEN
      PERFORM data.log_audit_event(
        NEW.tenant_id, auth.uid(), NULL,
        'CONTACT_DELIVERY_RULE_DISABLED', 'contact_delivery_rule', NEW.id,
        jsonb_build_object(
          'client_account_contact_id', NEW.client_account_contact_id,
          'purpose', NEW.purpose,
          'disable_reason', NEW.disable_reason
        )
      );
    ELSE
      PERFORM data.log_audit_event(
        NEW.tenant_id, auth.uid(), NULL,
        'CONTACT_DELIVERY_RULE_UPDATED', 'contact_delivery_rule', NEW.id,
        jsonb_build_object(
          'client_account_contact_id', NEW.client_account_contact_id,
          'purpose', NEW.purpose,
          'policy', NEW.policy
        )
      );
    END IF;
  END IF;
  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_contact_delivery_rules ON data.contact_delivery_rules;
CREATE TRIGGER trg_audit_contact_delivery_rules
  AFTER INSERT OR UPDATE ON data.contact_delivery_rules
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_contact_delivery_rules();

-- ---------------------------------------------------------------------------
-- 7. RLS
-- ---------------------------------------------------------------------------
ALTER TABLE data.contact_relationships ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.contact_delivery_channels ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.contact_delivery_rules ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "contact_relationships: select" ON data.contact_relationships;
CREATE POLICY "contact_relationships: select"
  ON data.contact_relationships FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

DROP POLICY IF EXISTS "contact_relationships: insert" ON data.contact_relationships;
CREATE POLICY "contact_relationships: insert"
  ON data.contact_relationships FOR INSERT TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role')
        IN ('owner', 'manager', 'member')
  );

DROP POLICY IF EXISTS "contact_relationships: update" ON data.contact_relationships;
CREATE POLICY "contact_relationships: update"
  ON data.contact_relationships FOR UPDATE TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role')
        IN ('owner', 'manager', 'member')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role')
        IN ('owner', 'manager', 'member')
  );

DROP POLICY IF EXISTS "contact_relationships: no delete" ON data.contact_relationships;

DROP POLICY IF EXISTS "contact_delivery_channels: select" ON data.contact_delivery_channels;
CREATE POLICY "contact_delivery_channels: select"
  ON data.contact_delivery_channels FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

DROP POLICY IF EXISTS "contact_delivery_channels: insert" ON data.contact_delivery_channels;
CREATE POLICY "contact_delivery_channels: insert"
  ON data.contact_delivery_channels FOR INSERT TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role')
        IN ('owner', 'manager', 'member')
  );

DROP POLICY IF EXISTS "contact_delivery_channels: update" ON data.contact_delivery_channels;
CREATE POLICY "contact_delivery_channels: update"
  ON data.contact_delivery_channels FOR UPDATE TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role')
        IN ('owner', 'manager', 'member')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role')
        IN ('owner', 'manager', 'member')
  );

DROP POLICY IF EXISTS "contact_delivery_rules: select" ON data.contact_delivery_rules;
CREATE POLICY "contact_delivery_rules: select"
  ON data.contact_delivery_rules FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

DROP POLICY IF EXISTS "contact_delivery_rules: insert" ON data.contact_delivery_rules;
CREATE POLICY "contact_delivery_rules: insert"
  ON data.contact_delivery_rules FOR INSERT TO authenticated
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role')
        IN ('owner', 'manager', 'member')
  );

DROP POLICY IF EXISTS "contact_delivery_rules: update" ON data.contact_delivery_rules;
CREATE POLICY "contact_delivery_rules: update"
  ON data.contact_delivery_rules FOR UPDATE TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role')
        IN ('owner', 'manager', 'member')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role')
        IN ('owner', 'manager', 'member')
  );

-- ---------------------------------------------------------------------------
-- 8. API views
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.contact_relationships
  WITH (security_invoker = true)
AS
SELECT
  r.id,
  r.tenant_id,
  r.organization_contact_id,
  r.person_contact_id,
  r.role::text AS role,
  r.starts_at,
  r.ends_at,
  r.revoked_at,
  r.revoked_by,
  r.revoke_reason,
  r.source,
  r.created_by,
  r.created_at,
  r.updated_at,
  org.display_name AS organization_display_name,
  per.display_name AS person_display_name,
  data.contact_relationship_is_live(r.revoked_at, r.starts_at, r.ends_at, now()) AS is_active
FROM data.contact_relationships r
JOIN data.contacts org ON org.id = r.organization_contact_id
JOIN data.contacts per ON per.id = r.person_contact_id
WHERE r.tenant_id = data.active_tenant_id();

CREATE OR REPLACE VIEW api.contact_delivery_channels
  WITH (security_invoker = true)
AS
SELECT
  c.id,
  c.tenant_id,
  c.contact_id,
  c.channel_type,
  c.value_raw,
  c.value_normalized,
  c.verified_at,
  c.verification_method,
  c.disabled_at,
  c.disabled_by,
  c.disable_reason,
  c.created_by,
  c.created_at,
  c.updated_at,
  ct.display_name AS contact_display_name,
  ct.kind::text AS contact_kind,
  (c.disabled_at IS NULL) AS is_active,
  (c.disabled_at IS NULL AND c.verified_at IS NOT NULL) AS is_verified
FROM data.contact_delivery_channels c
JOIN data.contacts ct ON ct.id = c.contact_id
WHERE c.tenant_id = data.active_tenant_id();

CREATE OR REPLACE VIEW api.contact_delivery_rules
  WITH (security_invoker = true)
AS
SELECT
  r.id,
  r.tenant_id,
  r.client_account_contact_id,
  r.contact_point_id,
  r.purpose,
  r.policy,
  r.disabled_at,
  r.disabled_by,
  r.disable_reason,
  r.created_by,
  r.created_at,
  r.updated_at,
  acc.display_name AS client_account_display_name,
  ch.channel_type,
  ch.value_normalized AS contact_point_value,
  ch.contact_id AS contact_point_contact_id,
  (r.disabled_at IS NULL) AS is_active
FROM data.contact_delivery_rules r
JOIN data.contacts acc ON acc.id = r.client_account_contact_id
JOIN data.contact_delivery_channels ch ON ch.id = r.contact_point_id
WHERE r.tenant_id = data.active_tenant_id();

GRANT SELECT ON api.contact_relationships TO authenticated;
GRANT SELECT ON api.contact_delivery_channels TO authenticated;
GRANT SELECT ON api.contact_delivery_rules TO authenticated;

-- ---------------------------------------------------------------------------
-- 9. RPCs
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.create_contact_relationship(
  p_organization_contact_id uuid,
  p_person_contact_id uuid,
  p_role text DEFAULT 'other',
  p_source text DEFAULT 'manual'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_id uuid;
  v_tenant uuid := data.active_tenant_id();
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;

  IF p_role IS NOT NULL AND p_role NOT IN ('primary', 'billing', 'operations', 'other') THEN
    RAISE EXCEPTION 'invalid_contact_relationship_role' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO data.contact_relationships (
    tenant_id,
    organization_contact_id,
    person_contact_id,
    role,
    source,
    created_by
  ) VALUES (
    v_tenant,
    p_organization_contact_id,
    p_person_contact_id,
    COALESCE(NULLIF(p_role, ''), 'other')::data.contact_relationship_role,
    COALESCE(NULLIF(p_source, ''), 'manual'),
    auth.uid()
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION api.revoke_contact_relationship(
  p_relationship_id uuid,
  p_reason text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
BEGIN
  UPDATE data.contact_relationships
  SET
    revoked_at = now(),
    ends_at = COALESCE(ends_at, now()),
    revoked_by = auth.uid(),
    revoke_reason = p_reason,
    updated_at = now()
  WHERE id = p_relationship_id
    AND tenant_id = data.active_tenant_id()
    AND revoked_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'contact_relationship_not_found_or_revoked'
      USING ERRCODE = 'P0001';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION api.create_contact_delivery_channel(
  p_contact_id uuid,
  p_channel_type text,
  p_value text,
  p_mark_verified boolean DEFAULT false,
  p_verification_method text DEFAULT 'staff_confirmed'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_id uuid;
  v_tenant uuid := data.active_tenant_id();
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;

  IF p_channel_type NOT IN ('email', 'phone') THEN
    RAISE EXCEPTION 'invalid_channel_type' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO data.contact_delivery_channels (
    tenant_id,
    contact_id,
    channel_type,
    value_raw,
    value_normalized,
    verified_at,
    verification_method,
    created_by
  ) VALUES (
    v_tenant,
    p_contact_id,
    p_channel_type,
    p_value,
    p_value, -- trigger normalises
    CASE WHEN p_mark_verified THEN now() ELSE NULL END,
    CASE WHEN p_mark_verified THEN COALESCE(NULLIF(p_verification_method, ''), 'staff_confirmed') ELSE NULL END,
    auth.uid()
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION api.verify_contact_delivery_channel(
  p_channel_id uuid,
  p_verification_method text DEFAULT 'staff_confirmed'
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
BEGIN
  UPDATE data.contact_delivery_channels
  SET
    verified_at = now(),
    verification_method = COALESCE(NULLIF(p_verification_method, ''), 'staff_confirmed'),
    updated_at = now()
  WHERE id = p_channel_id
    AND tenant_id = data.active_tenant_id()
    AND disabled_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'contact_delivery_channel_not_found'
      USING ERRCODE = 'P0001';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION api.disable_contact_delivery_channel(
  p_channel_id uuid,
  p_reason text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
BEGIN
  UPDATE data.contact_delivery_channels
  SET
    disabled_at = now(),
    disabled_by = auth.uid(),
    disable_reason = p_reason,
    updated_at = now()
  WHERE id = p_channel_id
    AND tenant_id = data.active_tenant_id()
    AND disabled_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'contact_delivery_channel_not_found_or_disabled'
      USING ERRCODE = 'P0001';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION api.create_contact_delivery_rule(
  p_client_account_contact_id uuid,
  p_contact_point_id uuid,
  p_purpose text,
  p_policy text DEFAULT 'manual'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_id uuid;
  v_tenant uuid := data.active_tenant_id();
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;

  IF p_purpose NOT IN ('bulletin', 'invoice') THEN
    RAISE EXCEPTION 'invalid_delivery_purpose' USING ERRCODE = 'P0001';
  END IF;

  IF COALESCE(p_policy, 'manual') NOT IN ('manual', 'on_publish') THEN
    RAISE EXCEPTION 'invalid_delivery_policy' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO data.contact_delivery_rules (
    tenant_id,
    client_account_contact_id,
    contact_point_id,
    purpose,
    policy,
    created_by
  ) VALUES (
    v_tenant,
    p_client_account_contact_id,
    p_contact_point_id,
    p_purpose,
    COALESCE(NULLIF(p_policy, ''), 'manual'),
    auth.uid()
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION api.disable_contact_delivery_rule(
  p_rule_id uuid,
  p_reason text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
BEGIN
  UPDATE data.contact_delivery_rules
  SET
    disabled_at = now(),
    disabled_by = auth.uid(),
    disable_reason = p_reason,
    updated_at = now()
  WHERE id = p_rule_id
    AND tenant_id = data.active_tenant_id()
    AND disabled_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'contact_delivery_rule_not_found_or_disabled'
      USING ERRCODE = 'P0001';
  END IF;
END;
$$;

GRANT SELECT, INSERT, UPDATE ON data.contact_relationships TO authenticated;
GRANT SELECT, INSERT, UPDATE ON data.contact_delivery_channels TO authenticated;
GRANT SELECT, INSERT, UPDATE ON data.contact_delivery_rules TO authenticated;

GRANT EXECUTE ON FUNCTION api.create_contact_relationship(uuid, uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION api.revoke_contact_relationship(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION api.create_contact_delivery_channel(uuid, text, text, boolean, text) TO authenticated;
GRANT EXECUTE ON FUNCTION api.verify_contact_delivery_channel(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION api.disable_contact_delivery_channel(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION api.create_contact_delivery_rule(uuid, uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION api.disable_contact_delivery_rule(uuid, text) TO authenticated;
