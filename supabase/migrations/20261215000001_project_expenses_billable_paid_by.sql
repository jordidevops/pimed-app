-- Gate Tall 2 → Tall 3 (slice): project_expenses.is_billable + paid_by.
-- Not EX0 / expenses product (no workflow, IVA, mileage, reports).

ALTER TABLE data.project_expenses
  ADD COLUMN IF NOT EXISTS is_billable boolean NOT NULL DEFAULT false;

ALTER TABLE data.project_expenses
  ADD COLUMN IF NOT EXISTS paid_by text NOT NULL DEFAULT 'company';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'project_expenses_paid_by_check'
      AND conrelid = 'data.project_expenses'::regclass
  ) THEN
    ALTER TABLE data.project_expenses
      ADD CONSTRAINT project_expenses_paid_by_check
      CHECK (paid_by IN ('company', 'employee'));
  END IF;
END;
$$;

COMMENT ON COLUMN data.project_expenses.is_billable IS
  'Marca de conciliació / imputació al client. No dispara facturació automàtica.';
COMMENT ON COLUMN data.project_expenses.paid_by IS
  'Qui ha avançat l''import: company | employee. Vocabulari alineat amb EXP.';

-- CREATE OR REPLACE cannot insert columns mid-list; drop first.
DROP VIEW IF EXISTS api.project_expenses;
CREATE VIEW api.project_expenses
  WITH (security_invoker = true) AS
  SELECT
    e.id,
    e.tenant_id,
    e.project_id,
    e.work_log_id,
    e.amount_cents,
    e.currency,
    e.description,
    e.category,
    e.receipt_document_id,
    e.is_billable,
    e.paid_by,
    e.created_by,
    e.created_at
  FROM data.project_expenses e;

REVOKE ALL ON api.project_expenses FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.project_expenses TO authenticated;

CREATE OR REPLACE FUNCTION api.add_project_expense(
  p_project_id uuid,
  p_description text,
  p_amount_cents integer,
  p_is_billable boolean DEFAULT false,
  p_paid_by text DEFAULT 'company',
  p_category text DEFAULT NULL,
  p_work_log_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_project data.projects%ROWTYPE;
  v_paid text := lower(NULLIF(btrim(COALESCE(p_paid_by, 'company')), ''));
  v_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;

  IF NULLIF(btrim(COALESCE(p_description, '')), '') IS NULL THEN
    RAISE EXCEPTION 'expense_description_required' USING ERRCODE = 'P0001';
  END IF;

  IF p_amount_cents IS NULL OR p_amount_cents < 0 THEN
    RAISE EXCEPTION 'expense_amount_invalid' USING ERRCODE = 'P0001';
  END IF;

  IF v_paid IS NULL OR v_paid NOT IN ('company', 'employee') THEN
    RAISE EXCEPTION 'expense_paid_by_invalid' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_project FROM data.projects WHERE id = p_project_id;
  IF NOT FOUND OR NOT data.can_execute_project(p_project_id) THEN
    RAISE EXCEPTION 'project_not_found_or_access_denied' USING ERRCODE = 'P0001';
  END IF;

  IF p_work_log_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM data.work_logs wl
    WHERE wl.id = p_work_log_id
      AND wl.project_id = p_project_id
      AND wl.tenant_id = v_project.tenant_id
  ) THEN
    RAISE EXCEPTION 'work_log_mismatch' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO data.project_expenses (
    tenant_id,
    project_id,
    work_log_id,
    amount_cents,
    currency,
    description,
    category,
    is_billable,
    paid_by,
    created_by
  ) VALUES (
    v_project.tenant_id,
    p_project_id,
    p_work_log_id,
    p_amount_cents,
    'EUR',
    btrim(p_description),
    NULLIF(btrim(COALESCE(p_category, '')), ''),
    COALESCE(p_is_billable, false),
    v_paid,
    v_uid
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION api.add_project_expense(
  uuid, text, integer, boolean, text, text, uuid
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.add_project_expense(
  uuid, text, integer, boolean, text, text, uuid
) TO authenticated, service_role;

COMMENT ON FUNCTION api.add_project_expense(
  uuid, text, integer, boolean, text, text, uuid
) IS
  'Gate slice: add a project expense with is_billable and paid_by. Online-only; no EXP workflow.';

NOTIFY pgrst, 'reload schema';
