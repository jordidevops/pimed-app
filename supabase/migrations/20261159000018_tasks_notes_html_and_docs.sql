-- =============================================================================
-- Field-service tasks: HTML notes for bulletin/albarà + documents on entity task
-- =============================================================================

ALTER TABLE data.tasks
  ADD COLUMN IF NOT EXISTS notes_html text;

COMMENT ON COLUMN data.tasks.notes_html IS
  'Rich-text work notes for the task (bulletin / delivery note).';

DROP VIEW IF EXISTS api.tasks CASCADE;
CREATE VIEW api.tasks
  WITH (security_invoker = true) AS
  SELECT
    id,
    tenant_id,
    project_id,
    title,
    status,
    assignee_id,
    position,
    due_date,
    created_at,
    updated_at,
    assignee_employee_id,
    source_checklist_run_item_id,
    notes_html
  FROM data.tasks;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.tasks TO authenticated, service_role;

INSERT INTO data.entity_types (
  code, label_key,
  supports_timeline, supports_documents, supports_signing, supports_subscriptions
)
SELECT 'task', 'entity_types.task', false, true, false, false
WHERE NOT EXISTS (
  SELECT 1 FROM data.entity_types et WHERE et.code = 'task'
);

NOTIFY pgrst, 'reload schema';
