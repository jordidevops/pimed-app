-- Signatura digital del registre mensual de jornada (RD 8/2019) via DMS/signing.

-- ── Columna enllaç signatura ─────────────────────────────────────────────────
ALTER TABLE data.attendance_monthly_reports
  ADD COLUMN IF NOT EXISTS signing_submission_id uuid
    REFERENCES data.signing_submissions(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_attendance_monthly_reports_signing
  ON data.attendance_monthly_reports (signing_submission_id)
  WHERE signing_submission_id IS NOT NULL;

-- ── Plantilla de plataforma (HTML) ─────────────────────────────────────────
INSERT INTO data.document_templates
  (id, tenant_id, name, description, category, template_type, is_platform_default, is_active, created_by)
VALUES
(
  '70000000-0000-0000-0000-000000000029',
  NULL,
  'Registre mensual de jornada',
  'Registre horari mensual per empleat (RD 8/2019). Signatura empleat + responsable.',
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
  '71000000-0000-0000-0000-000000000029',
  '70000000-0000-0000-0000-000000000029',
  'ca',
  'text/html',
  NULL,
  '<h1>Registre mensual de jornada</h1>
<p><strong>{{employee_name}}</strong> — {{period_label}}</p>
<p>Treballat: <strong>{{worked_hours}}</strong> · Previst: <strong>{{expected_hours}}</strong> · Diferència: <strong>{{difference_hours}}</strong></p>
{{report_body}}
<p style="font-size:12px;color:#6b7280;margin-top:16px;">Integritat del contingut (SHA-256): <code>{{content_hash}}</code></p>
<p>Declaro haver revisat el registre mensual de jornada conforme al Reial decret legislatiu 8/2019.</p>',
  '{
    "employee_name":     {"type":"string","label":"Nom empleat/da","required":true,"order":0},
    "period_label":      {"type":"string","label":"Període","required":true,"order":1},
    "worked_hours":      {"type":"string","label":"Hores treballades","required":true,"order":2},
    "expected_hours":    {"type":"string","label":"Hores previstes","required":true,"order":3},
    "difference_hours":  {"type":"string","label":"Diferència","required":true,"order":4},
    "report_body":       {"type":"string","label":"Detall dies","required":true,"order":5},
    "content_hash":      {"type":"string","label":"Hash contingut","required":false,"order":6}
  }',
  '{
    "Empleat":      {"entity_type":"employee","label":"Empleat/da","order":0,"for_signing":true},
    "Responsable":  {"entity_type":"user","label":"Responsable","order":1,"for_signing":true,"auto_assign_current_user":true}
  }',
  '{
    "employee_name":"Marta Rovira",
    "period_label":"juny de 2026",
    "worked_hours":"160:00",
    "expected_hours":"160:00",
    "difference_hours":"0:00",
    "report_body":"<table border=\"1\" cellpadding=\"4\"><tr><th>Data</th><th>Entrada</th><th>Sortida</th><th>Net</th></tr><tr><td>2026-06-02</td><td>09:00</td><td>18:00</td><td>8:00</td></tr></table>",
    "content_hash":"abc123"
  }',
  true
)
ON CONFLICT (id) DO UPDATE SET
  html_content           = EXCLUDED.html_content,
  variables_schema       = EXCLUDED.variables_schema,
  signing_roles_schema   = EXCLUDED.signing_roles_schema,
  is_active              = true;

-- ── Enllaç document + submissió després d'iniciar signatura ─────────────────
CREATE OR REPLACE FUNCTION api.link_attendance_monthly_report_signing(
  p_employee_id             uuid,
  p_year                    int,
  p_month                   int,
  p_document_id             uuid,
  p_signing_submission_id   uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_emp   record;
  v_id    uuid;
BEGIN
  SELECT e.tenant_id, e.site_id INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found';
  END IF;

  IF NOT data.jwt_has_permission(v_emp.tenant_id, 'attendance.approve', v_emp.site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege';
  END IF;

  IF p_month < 1 OR p_month > 12 THEN
    RAISE EXCEPTION 'invalid_month';
  END IF;

  UPDATE data.attendance_monthly_reports amr
  SET
    document_id           = p_document_id,
    signing_submission_id = p_signing_submission_id,
    updated_at            = now()
  WHERE amr.employee_id = p_employee_id
    AND amr.year = p_year
    AND amr.month = p_month
    AND amr.status IN ('employee_confirmed', 'manager_approved', 'signed')
  RETURNING amr.id INTO v_id;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'report_not_ready_for_signing';
  END IF;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.link_attendance_monthly_report_signing(uuid, int, int, uuid, uuid) TO authenticated;

-- ── Marcar signat quan la submissió es completa ─────────────────────────────
CREATE OR REPLACE FUNCTION data.trg_mark_attendance_monthly_report_signed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF NEW.status = 'completed' AND (OLD.status IS DISTINCT FROM 'completed') THEN
    UPDATE data.attendance_monthly_reports amr
    SET status = 'signed', updated_at = now()
    WHERE amr.status = 'manager_approved'
      AND (
        amr.signing_submission_id = NEW.id
        OR (amr.document_id IS NOT NULL AND amr.document_id = NEW.source_document_id)
      );
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_attendance_monthly_report_signed ON data.signing_submissions;
CREATE TRIGGER trg_attendance_monthly_report_signed
  AFTER UPDATE OF status ON data.signing_submissions
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_mark_attendance_monthly_report_signed();

-- Refrescar vista API (SELECT * no afegeix columnes noves automàticament)
CREATE OR REPLACE VIEW api.attendance_monthly_reports
  WITH (security_invoker = true) AS
  SELECT * FROM data.attendance_monthly_reports;

GRANT SELECT ON api.attendance_monthly_reports TO authenticated;

NOTIFY pgrst, 'reload schema';
