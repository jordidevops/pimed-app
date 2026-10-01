-- CT-4: link/unlink agreements to projects, and block field start when a
-- require_signed_agreement gate is not active. Unlink writes an event and
-- does not touch DMS files or signatures.

CREATE OR REPLACE FUNCTION data.project_requires_active_agreement(p_project_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM data.commercial_agreement_projects cap
    JOIN data.commercial_agreements a ON a.id = cap.agreement_id
    WHERE cap.project_id = p_project_id
      AND a.work_gate = 'require_signed_agreement'
      AND a.status NOT IN ('cancelled', 'finished')
      AND a.status IS DISTINCT FROM 'active'
  );
$$;

COMMENT ON FUNCTION data.project_requires_active_agreement(uuid) IS
  'True when a linked agreement demands an active contract before field work. work_gate=none never blocks.';

REVOKE ALL ON FUNCTION data.project_requires_active_agreement(uuid) FROM PUBLIC;

CREATE OR REPLACE FUNCTION data.trg_work_logs_agreement_gate()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.status = 'open'
     AND data.project_requires_active_agreement(NEW.project_id) THEN
    RAISE EXCEPTION 'agreement_work_gate_blocked' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_work_logs_agreement_gate ON data.work_logs;
CREATE TRIGGER trg_work_logs_agreement_gate
  BEFORE INSERT ON data.work_logs
  FOR EACH ROW EXECUTE FUNCTION data.trg_work_logs_agreement_gate();

CREATE OR REPLACE FUNCTION api.link_agreement_project(
  p_agreement_id uuid,
  p_project_id uuid,
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
  v_project data.projects%ROWTYPE;
  v_event data.commercial_agreement_events%ROWTYPE;
  v_link_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_agreement
  FROM data.commercial_agreements
  WHERE id = p_agreement_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_agreement.tenant_id::text) THEN
    RAISE EXCEPTION 'agreement_not_found' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_event
  FROM data.commercial_agreement_events
  WHERE tenant_id = v_agreement.tenant_id
    AND client_op_id = p_client_op_id;
  IF FOUND THEN
    IF v_event.event_type IS DISTINCT FROM 'project_linked'
       OR v_event.agreement_id IS DISTINCT FROM p_agreement_id THEN
      RAISE EXCEPTION 'client_op_conflict' USING ERRCODE = 'P0001';
    END IF;
    RETURN (v_event.payload->>'link_id')::uuid;
  END IF;

  IF COALESCE((
    SELECT tm.role
    FROM data.tenant_members tm
    WHERE tm.tenant_id = v_agreement.tenant_id
      AND tm.user_id = v_uid
      AND tm.site_id IS NULL
    LIMIT 1
  ), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'permission_denied:agreement_prepare' USING ERRCODE = 'P0001';
  END IF;

  IF v_agreement.status = 'cancelled' THEN
    RAISE EXCEPTION 'agreement_not_linkable' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_project FROM data.projects WHERE id = p_project_id;
  IF NOT FOUND OR v_project.tenant_id IS DISTINCT FROM v_agreement.tenant_id THEN
    RAISE EXCEPTION 'agreement_project_tenant_mismatch' USING ERRCODE = 'P0001';
  END IF;
  IF v_project.client_id IS DISTINCT FROM v_agreement.client_id THEN
    RAISE EXCEPTION 'agreement_project_client_mismatch' USING ERRCODE = 'P0001';
  END IF;

  SELECT id INTO v_link_id
  FROM data.commercial_agreement_projects
  WHERE agreement_id = p_agreement_id
    AND project_id = p_project_id;
  IF v_link_id IS NOT NULL THEN
    RETURN v_link_id;
  END IF;

  INSERT INTO data.commercial_agreement_projects (tenant_id, agreement_id, project_id)
  VALUES (v_agreement.tenant_id, p_agreement_id, p_project_id)
  RETURNING id INTO v_link_id;

  INSERT INTO data.commercial_agreement_events (
    tenant_id, agreement_id, event_type, actor_id, client_op_id, payload
  ) VALUES (
    v_agreement.tenant_id,
    p_agreement_id,
    'project_linked',
    v_uid,
    p_client_op_id,
    jsonb_build_object('project_id', p_project_id, 'link_id', v_link_id)
  );

  RETURN v_link_id;
END;
$$;

COMMENT ON FUNCTION api.link_agreement_project(uuid, uuid, uuid) IS
  'Vincula un acord a un projecte del mateix client. Idempotent. No copia PDFs.';

REVOKE ALL ON FUNCTION api.link_agreement_project(uuid, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.link_agreement_project(uuid, uuid, uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.unlink_agreement_project(
  p_agreement_id uuid,
  p_project_id uuid,
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
  v_version_status text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_agreement
  FROM data.commercial_agreements
  WHERE id = p_agreement_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_agreement.tenant_id::text) THEN
    RAISE EXCEPTION 'agreement_not_found' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_event
  FROM data.commercial_agreement_events
  WHERE tenant_id = v_agreement.tenant_id
    AND client_op_id = p_client_op_id;
  IF FOUND THEN
    IF v_event.event_type IS DISTINCT FROM 'project_unlinked'
       OR v_event.agreement_id IS DISTINCT FROM p_agreement_id THEN
      RAISE EXCEPTION 'client_op_conflict' USING ERRCODE = 'P0001';
    END IF;
    RETURN;
  END IF;

  IF COALESCE((
    SELECT tm.role
    FROM data.tenant_members tm
    WHERE tm.tenant_id = v_agreement.tenant_id
      AND tm.user_id = v_uid
      AND tm.site_id IS NULL
    LIMIT 1
  ), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'permission_denied:agreement_prepare' USING ERRCODE = 'P0001';
  END IF;

  SELECT id INTO v_link_id
  FROM data.commercial_agreement_projects
  WHERE agreement_id = p_agreement_id
    AND project_id = p_project_id;
  IF v_link_id IS NULL THEN
    RAISE EXCEPTION 'agreement_project_not_linked' USING ERRCODE = 'P0001';
  END IF;

  SELECT v.status INTO v_version_status
  FROM data.commercial_agreement_versions v
  WHERE v.id = v_agreement.active_version_id;

  IF v_agreement.work_gate = 'require_signed_agreement'
     AND v_agreement.status NOT IN ('cancelled', 'finished')
     AND (
       v_agreement.status = 'active'
       OR v_version_status = 'pending_signature'
     ) THEN
    RAISE EXCEPTION 'agreement_unlink_forbidden' USING ERRCODE = 'P0001';
  END IF;

  DELETE FROM data.commercial_agreement_projects WHERE id = v_link_id;

  INSERT INTO data.commercial_agreement_events (
    tenant_id, agreement_id, event_type, actor_id, client_op_id, payload
  ) VALUES (
    v_agreement.tenant_id,
    p_agreement_id,
    'project_unlinked',
    v_uid,
    p_client_op_id,
    jsonb_build_object('project_id', p_project_id, 'link_id', v_link_id)
  );
END;
$$;

COMMENT ON FUNCTION api.unlink_agreement_project(uuid, uuid, uuid) IS
  'Desvincula l''acord del projecte i deixa event. No esborra PDFs ni desfirma. Prohibit si el gate require_signed_agreement governa (actiu o pendent de firma).';

REVOKE ALL ON FUNCTION api.unlink_agreement_project(uuid, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.unlink_agreement_project(uuid, uuid, uuid) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
