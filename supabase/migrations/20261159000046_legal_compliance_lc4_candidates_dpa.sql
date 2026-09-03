-- LC-4: unify privacy_candidates (migrate legacy recruitment URL) + DPA soft-duty ack

-- =============================================================================
-- 1. DPA acknowledgement on legal profile (soft-duty; no hard block)
-- =============================================================================

ALTER TABLE data.tenant_legal_profiles
  ADD COLUMN IF NOT EXISTS dpa_acknowledged_at timestamptz,
  ADD COLUMN IF NOT EXISTS dpa_acknowledged_by uuid REFERENCES auth.users (id);

COMMENT ON COLUMN data.tenant_legal_profiles.dpa_acknowledged_at IS
  'LC-4 soft-duty: tenant staff reviewed platform DPA (dpa_platform). Not commercial e-sign.';

-- =============================================================================
-- 2. One-shot: recruitment privacy_policy_url → Legal Center external_url
--    Only when document is still default template and URL is non-empty.
-- =============================================================================

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT rs.tenant_id, NULLIF(btrim(rs.privacy_policy_url), '') AS url
    FROM data.recruitment_settings rs
    WHERE NULLIF(btrim(COALESCE(rs.privacy_policy_url, '')), '') IS NOT NULL
  LOOP
    PERFORM data.ensure_tenant_legal_profile(r.tenant_id);

    UPDATE data.tenant_legal_documents d
    SET mode = 'external_url',
        external_url = r.url,
        updated_at = now()
    WHERE d.tenant_id = r.tenant_id
      AND d.code = 'privacy_candidates'
      AND d.mode = 'template'
      AND NULLIF(btrim(COALESCE(d.external_url, '')), '') IS NULL;
  END LOOP;
END;
$$;

COMMENT ON COLUMN data.recruitment_settings.privacy_policy_url IS
  'DEPRECATED LC-4: careers read Legal Center privacy_candidates. Kept for fallback only; do not edit in UI.';

-- =============================================================================
-- 3. get_my_tenant_legal_center: expose dpa_acknowledged
-- =============================================================================

CREATE OR REPLACE FUNCTION api.get_my_tenant_legal_center()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_profile data.tenant_legal_profiles%ROWTYPE;
  v_docs jsonb;
  v_incomplete boolean;
  v_dpa_ack boolean;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  PERFORM data.require_fresh_tenant_permission(v_tenant, 'settings.manage', NULL);
  v_profile := data.ensure_tenant_legal_profile(v_tenant);

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', d.id,
      'code', d.code,
      'mode', d.mode,
      'external_url', d.external_url,
      'updated_at', d.updated_at
    )
    ORDER BY d.code
  ), '[]'::jsonb)
  INTO v_docs
  FROM data.tenant_legal_documents d
  WHERE d.tenant_id = v_tenant;

  v_incomplete :=
    NULLIF(btrim(COALESCE(v_profile.legal_name, '')), '') IS NULL
    OR NULLIF(btrim(COALESCE(v_profile.privacy_email, '')), '') IS NULL;

  v_dpa_ack := v_profile.dpa_acknowledged_at IS NOT NULL;

  RETURN jsonb_build_object(
    'profile', to_jsonb(v_profile),
    'documents', v_docs,
    'incomplete', v_incomplete,
    'dpa_acknowledged', v_dpa_ack,
    'dpa_acknowledged_at', v_profile.dpa_acknowledged_at,
    'disclaimer',
      'Les plantilles són orientatives. El tenant és el responsable del tractament; la plataforma és l''encarregat sota DPA.',
    'privacy_candidates_note',
      'Les candidatures públiques (careers) usen el document privacy_candidates del Legal Center (ja no la URL de recruitment_settings).'
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_my_tenant_legal_center() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_my_tenant_legal_center() TO authenticated;

-- =============================================================================
-- 4. Acknowledge platform DPA (soft)
-- =============================================================================

CREATE OR REPLACE FUNCTION api.acknowledge_my_tenant_platform_dpa()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  PERFORM data.require_fresh_tenant_permission(v_tenant, 'settings.manage', NULL);
  PERFORM data.ensure_tenant_legal_profile(v_tenant);

  UPDATE data.tenant_legal_profiles
  SET dpa_acknowledged_at = COALESCE(dpa_acknowledged_at, now()),
      dpa_acknowledged_by = COALESCE(dpa_acknowledged_by, auth.uid()),
      updated_at = now(),
      updated_by = auth.uid()
  WHERE tenant_id = v_tenant;

  PERFORM data.log_audit_event_strict(
    v_tenant, auth.uid(), NULL::uuid,
    'TENANT_PLATFORM_DPA_ACKNOWLEDGED',
    'tenant_legal_profile', v_tenant,
    jsonb_build_object('document', 'dpa_platform', 'soft_duty', true)
  );

  RETURN api.get_my_tenant_legal_center();
END;
$$;

REVOKE ALL ON FUNCTION api.acknowledge_my_tenant_platform_dpa() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.acknowledge_my_tenant_platform_dpa() TO authenticated;
