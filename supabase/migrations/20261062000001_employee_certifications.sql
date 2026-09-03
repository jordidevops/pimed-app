-- =============================================================================
-- M-CR-03 — employee_certifications + compute_certification_status
-- =============================================================================

CREATE OR REPLACE FUNCTION data.compute_certification_status(
  p_valid_from  date,
  p_valid_until date,
  p_as_of       date DEFAULT CURRENT_DATE
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_valid_until IS NULL THEN 'indefinite'
    WHEN p_as_of > p_valid_until THEN 'expired'
    WHEN p_as_of >= p_valid_from AND p_valid_until - p_as_of <= 30 THEN 'expiring_soon'
    WHEN p_as_of < p_valid_from THEN 'not_yet_valid'
    ELSE 'active'
  END;
$$;

GRANT EXECUTE ON FUNCTION data.compute_certification_status(date, date, date) TO authenticated, service_role;

CREATE TABLE IF NOT EXISTS data.employee_certifications (
  id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  employee_id         uuid        NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  requirement_type_id uuid        NOT NULL REFERENCES data.compliance_requirement_types(id),
  issuer              text,
  credential_number   text,
  issued_on           date,
  valid_from          date        NOT NULL DEFAULT CURRENT_DATE,
  valid_until         date,
  document_id         uuid        REFERENCES data.documents(id) ON DELETE SET NULL,
  revoked_at          timestamptz,
  revoked_reason      text,
  notes               text,
  created_by          uuid        NOT NULL REFERENCES data.profiles(id),
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT employee_certifications_valid_range
    CHECK (valid_until IS NULL OR valid_until >= valid_from)
);

CREATE INDEX IF NOT EXISTS idx_employee_certifications_employee
  ON data.employee_certifications (employee_id, requirement_type_id);

CREATE INDEX IF NOT EXISTS idx_employee_certifications_expiry
  ON data.employee_certifications (tenant_id, valid_until)
  WHERE valid_until IS NOT NULL AND revoked_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_employee_certifications_tenant
  ON data.employee_certifications (tenant_id, employee_id);

DROP TRIGGER IF EXISTS trg_employee_certifications_updated_at ON data.employee_certifications;
CREATE TRIGGER trg_employee_certifications_updated_at
  BEFORE UPDATE ON data.employee_certifications
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

ALTER TABLE data.employee_certifications ENABLE ROW LEVEL SECURITY;

GRANT SELECT ON data.employee_certifications TO authenticated, service_role;
GRANT INSERT, UPDATE ON data.employee_certifications TO service_role;
-- DELETE bloquejat deliberadament (revocació via revoked_at)

CREATE OR REPLACE VIEW api.employee_certifications
  WITH (security_invoker = true) AS
SELECT
  c.id,
  c.tenant_id,
  c.employee_id,
  c.requirement_type_id,
  c.issuer,
  c.credential_number,
  c.issued_on,
  c.valid_from,
  c.valid_until,
  c.document_id,
  c.revoked_at,
  c.revoked_reason,
  c.notes,
  c.created_by,
  c.created_at,
  c.updated_at,
  data.compute_certification_status(c.valid_from, c.valid_until, CURRENT_DATE) AS computed_status,
  t.code AS requirement_code,
  t.name AS requirement_name,
  t.category AS requirement_category
FROM data.employee_certifications c
JOIN data.compliance_requirement_types t ON t.id = c.requirement_type_id;

GRANT SELECT ON api.employee_certifications TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
