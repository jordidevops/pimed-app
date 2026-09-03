-- Track G Phase 6: attendance protocol (DMS) + employee portal document assignments

-- --- 1. Assignments table ---

CREATE TABLE IF NOT EXISTS data.employee_portal_document_assignments (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id               uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  employee_id             uuid NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  assignment_kind         text NOT NULL DEFAULT 'attendance_protocol',
  document_version_id     uuid NOT NULL REFERENCES data.document_versions(id) ON DELETE CASCADE,
  published_at            timestamptz NOT NULL DEFAULT now(),
  published_by            uuid REFERENCES auth.users(id),
  acknowledged_at         timestamptz,
  signature_submission_id uuid REFERENCES data.signing_submissions(id) ON DELETE SET NULL,
  UNIQUE (employee_id, document_version_id)
);

CREATE INDEX IF NOT EXISTS idx_epda_employee_kind
  ON data.employee_portal_document_assignments (employee_id, assignment_kind, published_at DESC);

CREATE INDEX IF NOT EXISTS idx_epda_tenant
  ON data.employee_portal_document_assignments (tenant_id, assignment_kind);

-- --- 2. RLS ---

ALTER TABLE data.employee_portal_document_assignments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS epda_manager_read ON data.employee_portal_document_assignments;
CREATE POLICY epda_manager_read ON data.employee_portal_document_assignments
  FOR SELECT TO authenticated
  USING (
    tenant_id = data.active_tenant_id()
    AND data.jwt_has_permission(tenant_id, 'attendance.view_all', NULL)
  );

DROP POLICY IF EXISTS epda_service_all ON data.employee_portal_document_assignments;
CREATE POLICY epda_service_all ON data.employee_portal_document_assignments
  FOR ALL TO service_role
  USING (true) WITH CHECK (true);

-- --- 3. Settings ---

INSERT INTO data.settings_registry
  (setting_key, scope, required_permission, owner_only, is_active, description)
VALUES
  ('attendance_protocol_requires_signature', 'tenant', 'settings.manage', false, true,
   'El protocol de registre horari requereix signatura digital (L2) en lloc de només lectura + checkbox (L1)'),
  ('attendance_protocol_required_before_punch', 'tenant', 'settings.manage', false, true,
   'Bloqueja el primer fitxatge al portal fins que l''empleat llegeixi/confirimi el protocol publicat')
ON CONFLICT (setting_key) DO UPDATE SET
  description = EXCLUDED.description,
  updated_at = now();

INSERT INTO data.system_settings (module, settings)
VALUES ('defaults', '{
  "attendance_protocol_requires_signature": false,
  "attendance_protocol_required_before_punch": false
}'::jsonb)
ON CONFLICT (module) DO UPDATE
  SET settings = data.system_settings.settings || EXCLUDED.settings,
      updated_at = now();

-- --- 4. Platform template: Protocol de registre horari ---

INSERT INTO data.document_templates
  (id, tenant_id, name, description, category, template_type, is_platform_default, is_active, created_by)
VALUES
(
  '70000000-0000-0000-0000-000000000030',
  NULL,
  'Protocol de registre horari',
  'Informació per a l''empleat sobre com es calculen presència, temps efectiu i temps remunerable.',
  'attendance',
  'html',
  true,
  true,
  NULL
)
ON CONFLICT (id) DO UPDATE SET
  name        = EXCLUDED.name,
  description = EXCLUDED.description,
  category    = EXCLUDED.category,
  is_active   = true;

INSERT INTO data.document_template_locales
  (id, template_id, locale, mime_type, storage_path, html_content, variables_schema, signing_roles_schema, sample_values, is_active)
VALUES
(
  '71000000-0000-0000-0000-000000000030',
  '70000000-0000-0000-0000-000000000030',
  'ca',
  'text/html',
  NULL,
  '<h1>Protocol de registre horari</h1>
<p><strong>{{employee_name}}</strong> — {{tenant_name}}</p>
<p>Perfil de jornada: <strong>{{work_profile_label}}</strong> · Jurisdicció: <strong>{{jurisdiction_code}}</strong></p>
<h2>1. Conceptes</h2>
<ul>
  <li><strong>Presència</strong>: temps entre entrada i sortida, incloses pauses.</li>
  <li><strong>Temps efectiu / treball net</strong>: temps de treball descomptant pauses no remunerades.</li>
  <li><strong>Temps remunerable</strong>: base per a nòmina segons política del conveni (pot incloure desplaçament segons perfil).</li>
  <li><strong>Hores extra</strong>: minuts fora de la jornada prevista; poden requerir autorització prèvia.</li>
</ul>
<h2>2. El teu perfil ({{work_profile_label}})</h2>
<p>{{profile_explanation}}</p>
<h2>3. Revisió mensual</h2>
<p>Abans del tancament de nòmina podràs revisar el registre mensual al portal i confirmar-lo o signar-lo si l''empresa ho requereix.</p>
<h2>4. Reclamacions</h2>
<p>Si detectes un error, contacta amb el teu responsable abans del tancament mensual. Les correccions queden auditades.</p>
<p style="font-size:12px;color:#6b7280;margin-top:24px;">Aquest document és informatiu i no substitueix assessorament legal. Publicat: {{published_date}}.</p>',
  '{
    "employee_name":       {"type":"string","label":"Nom empleat","required":true,"order":0},
    "tenant_name":         {"type":"string","label":"Empresa","required":true,"order":1},
    "work_profile_label":  {"type":"string","label":"Perfil jornada","required":true,"order":2},
    "jurisdiction_code":   {"type":"string","label":"Jurisdicció","required":true,"order":3},
    "profile_explanation": {"type":"string","label":"Explicació perfil","required":true,"order":4},
    "published_date":      {"type":"string","label":"Data publicació","required":true,"order":5}
  }',
  '{
    "Empleat": {"entity_type":"employee","label":"Empleat/da","order":0,"for_signing":true}
  }',
  '{
    "employee_name":"Marta Rovira",
    "tenant_name":"Acme SL",
    "work_profile_label":"Oficina / centre fix",
    "jurisdiction_code":"ES",
    "profile_explanation":"Les hores es calculen segons l''horari programat al centre. Els desplaçaments no compten com a jornada excepte si la política del conveni ho indica.",
    "published_date":"2026-07-01"
  }',
  true
)
ON CONFLICT (id) DO UPDATE SET
  html_content         = EXCLUDED.html_content,
  variables_schema     = EXCLUDED.variables_schema,
  signing_roles_schema = EXCLUDED.signing_roles_schema,
  is_active            = true;

-- --- 5. Manager: create assignment ---

CREATE OR REPLACE FUNCTION api.create_attendance_protocol_assignment(
  p_employee_id           uuid,
  p_document_version_id   uuid,
  p_signing_submission_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp record;
  v_doc record;
  v_id  uuid;
BEGIN
  SELECT e.id, e.tenant_id, e.site_id INTO v_emp
  FROM data.employees e WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found';
  END IF;

  IF NOT data.jwt_has_permission(v_emp.tenant_id, 'attendance.manage', v_emp.site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege';
  END IF;

  SELECT d.tenant_id, d.title INTO v_doc
  FROM data.document_versions dv
  JOIN data.documents d ON d.id = dv.document_id
  WHERE dv.id = p_document_version_id;

  IF NOT FOUND OR v_doc.tenant_id IS DISTINCT FROM v_emp.tenant_id THEN
    RAISE EXCEPTION 'document_version_not_found';
  END IF;

  INSERT INTO data.employee_portal_document_assignments (
    tenant_id, employee_id, assignment_kind,
    document_version_id, published_by, signature_submission_id
  ) VALUES (
    v_emp.tenant_id, p_employee_id, 'attendance_protocol',
    p_document_version_id, auth.uid(), p_signing_submission_id
  )
  ON CONFLICT (employee_id, document_version_id) DO UPDATE SET
    published_at = now(),
    published_by = auth.uid(),
    signature_submission_id = COALESCE(EXCLUDED.signature_submission_id, data.employee_portal_document_assignments.signature_submission_id),
    acknowledged_at = NULL
  RETURNING id INTO v_id;

  PERFORM data.log_attendance_employee_audit(
    v_emp.tenant_id, auth.uid(), v_emp.site_id, p_employee_id,
    'ATTENDANCE_PROTOCOL_PUBLISHED',
    jsonb_build_object(
      'assignment_id', v_id,
      'document_version_id', p_document_version_id,
      'signing_submission_id', p_signing_submission_id
    )
  );

  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION api.link_attendance_protocol_signing(
  p_assignment_id           uuid,
  p_signing_submission_id   uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_row record;
BEGIN
  SELECT a.*, e.site_id INTO v_row
  FROM data.employee_portal_document_assignments a
  JOIN data.employees e ON e.id = a.employee_id
  WHERE a.id = p_assignment_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'assignment_not_found';
  END IF;

  IF NOT data.jwt_has_permission(v_row.tenant_id, 'attendance.manage', v_row.site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege';
  END IF;

  UPDATE data.employee_portal_document_assignments
  SET signature_submission_id = p_signing_submission_id
  WHERE id = p_assignment_id;

  RETURN p_assignment_id;
END;
$$;

-- --- 6. Portal RPCs (service_role) ---

CREATE OR REPLACE FUNCTION api.employee_portal_list_documents(
  p_employee_id uuid,
  p_tenant_id   uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_settings jsonb;
  v_requires_sig boolean;
  v_site_id uuid;
  v_rows jsonb := '[]'::jsonb;
  v_rec record;
  v_signing record;
  v_sign_url text;
  v_completed boolean;
  v_pending boolean;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM data.employees e
    WHERE e.id = p_employee_id AND e.tenant_id = p_tenant_id
  ) THEN
    RAISE EXCEPTION 'employee_not_found';
  END IF;

  SELECT e.site_id INTO v_site_id
  FROM data.employees e
  WHERE e.id = p_employee_id AND e.tenant_id = p_tenant_id;

  v_settings := data.merge_effective_settings_for_service(p_tenant_id, v_site_id);
  v_requires_sig := COALESCE((v_settings->>'attendance_protocol_requires_signature')::boolean, false);

  FOR v_rec IN
    SELECT
      a.id,
      a.assignment_kind,
      a.published_at,
      a.acknowledged_at,
      a.signature_submission_id,
      d.title,
      dv.id AS version_id,
      dv.mime_type,
      dv.file_path_or_url
    FROM data.employee_portal_document_assignments a
    JOIN data.document_versions dv ON dv.id = a.document_version_id
    JOIN data.documents d ON d.id = dv.document_id
    WHERE a.employee_id = p_employee_id
      AND a.tenant_id = p_tenant_id
    ORDER BY a.published_at DESC
    LIMIT 20
  LOOP
    v_sign_url := NULL;
    v_completed := false;
    v_pending := v_rec.acknowledged_at IS NULL;

    IF v_rec.signature_submission_id IS NOT NULL THEN
      SELECT ss.status, ss.signers INTO v_signing
      FROM data.signing_submissions ss
      WHERE ss.id = v_rec.signature_submission_id;

      v_completed := v_signing.status = 'completed';
      v_pending := NOT v_completed;

      IF NOT v_completed THEN
        SELECT s->>'signing_url' INTO v_sign_url
        FROM jsonb_array_elements(COALESCE(v_signing.signers, '[]'::jsonb)) s
        WHERE (s->>'role') = 'Empleat'
        LIMIT 1;
      END IF;
    ELSIF v_requires_sig AND v_rec.assignment_kind = 'attendance_protocol' THEN
      v_pending := v_rec.acknowledged_at IS NULL;
    END IF;

    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'id', v_rec.id,
      'assignment_kind', v_rec.assignment_kind,
      'title', v_rec.title,
      'published_at', v_rec.published_at,
      'acknowledged_at', v_rec.acknowledged_at,
      'requires_signature', v_requires_sig AND v_rec.assignment_kind = 'attendance_protocol',
      'signature_submission_id', v_rec.signature_submission_id,
      'signature_completed', v_completed,
      'employee_sign_url', v_sign_url,
      'is_pending', v_pending,
      'document_version_id', v_rec.version_id,
      'mime_type', v_rec.mime_type,
      'storage_path', v_rec.file_path_or_url
    ));
  END LOOP;

  RETURN jsonb_build_object(
    'employee_id', p_employee_id,
    'documents', v_rows,
    'settings', jsonb_build_object(
      'requires_signature', v_requires_sig,
      'required_before_punch', COALESCE((v_settings->>'attendance_protocol_required_before_punch')::boolean, false)
    )
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.employee_portal_acknowledge_document(
  p_employee_id   uuid,
  p_tenant_id     uuid,
  p_assignment_id uuid
)
RETURNS timestamptz
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_row record;
  v_settings jsonb;
  v_requires_sig boolean;
BEGIN
  SELECT a.*, e.site_id INTO v_row
  FROM data.employee_portal_document_assignments a
  JOIN data.employees e ON e.id = a.employee_id
  WHERE a.id = p_assignment_id
    AND a.employee_id = p_employee_id
    AND a.tenant_id = p_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'assignment_not_found';
  END IF;

  v_settings := data.merge_effective_settings_for_service(p_tenant_id, v_row.site_id);
  v_requires_sig := COALESCE((v_settings->>'attendance_protocol_requires_signature')::boolean, false);

  IF v_requires_sig AND v_row.assignment_kind = 'attendance_protocol' THEN
    RAISE EXCEPTION 'signature_required' USING ERRCODE = 'check_violation';
  END IF;

  IF v_row.acknowledged_at IS NOT NULL THEN
    RETURN v_row.acknowledged_at;
  END IF;

  UPDATE data.employee_portal_document_assignments
  SET acknowledged_at = now()
  WHERE id = p_assignment_id
  RETURNING acknowledged_at INTO v_row.acknowledged_at;

  PERFORM data.log_attendance_employee_audit(
    p_tenant_id, NULL, v_row.site_id, p_employee_id,
    'ATTENDANCE_PROTOCOL_ACKNOWLEDGED',
    jsonb_build_object('assignment_id', p_assignment_id)
  );

  RETURN v_row.acknowledged_at;
END;
$$;

CREATE OR REPLACE FUNCTION api.employee_portal_has_pending_protocol(
  p_employee_id uuid,
  p_tenant_id   uuid
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_settings jsonb;
  v_site_id uuid;
  v_required boolean;
BEGIN
  SELECT e.site_id INTO v_site_id
  FROM data.employees e
  WHERE e.id = p_employee_id AND e.tenant_id = p_tenant_id;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  v_settings := data.merge_effective_settings_for_service(p_tenant_id, v_site_id);
  v_required := COALESCE((v_settings->>'attendance_protocol_required_before_punch')::boolean, false);

  IF NOT v_required THEN
    RETURN false;
  END IF;

  RETURN EXISTS (
    SELECT 1
    FROM data.employee_portal_document_assignments a
    LEFT JOIN data.signing_submissions s ON s.id = a.signature_submission_id
    WHERE a.employee_id = p_employee_id
      AND a.tenant_id = p_tenant_id
      AND a.assignment_kind = 'attendance_protocol'
      AND (
        (a.signature_submission_id IS NULL AND a.acknowledged_at IS NULL)
        OR (a.signature_submission_id IS NOT NULL AND COALESCE(s.status, '') <> 'completed')
      )
  );
END;
$$;

-- Mark assignment acknowledged when signature completes
CREATE OR REPLACE FUNCTION data.trg_mark_portal_document_assignment_signed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF NEW.status = 'completed' AND (OLD.status IS DISTINCT FROM 'completed') THEN
    UPDATE data.employee_portal_document_assignments
    SET acknowledged_at = COALESCE(acknowledged_at, now())
    WHERE signature_submission_id = NEW.id;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_portal_document_assignment_signed ON data.signing_submissions;
CREATE TRIGGER trg_portal_document_assignment_signed
  AFTER UPDATE OF status ON data.signing_submissions
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_mark_portal_document_assignment_signed();

GRANT EXECUTE ON FUNCTION api.create_attendance_protocol_assignment(uuid, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION api.link_attendance_protocol_signing(uuid, uuid) TO authenticated;

REVOKE ALL ON FUNCTION api.employee_portal_list_documents(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.employee_portal_acknowledge_document(uuid, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.employee_portal_has_pending_protocol(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.employee_portal_list_documents(uuid, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION api.employee_portal_acknowledge_document(uuid, uuid, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION api.employee_portal_has_pending_protocol(uuid, uuid) TO service_role;

NOTIFY pgrst, 'reload schema';
