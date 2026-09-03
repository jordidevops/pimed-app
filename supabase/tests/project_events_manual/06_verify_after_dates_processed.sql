-- Step 06: Run this after processing the worker a second time.
-- Expected: one calendar event for this project with the planned_start value.
-- Notes:
--   - If step 05 used PROJECT_DATES_SET, notifications count should stay unchanged.
--   - If step 05 used PROJECT_CREATED fallback, notifications will increase.

SELECT
  ce.id,
  ce.tenant_id,
  ce.site_id,
  ce.title,
  ce.start_at,
  ce.end_at,
  ce.entity_type,
  ce.entity_id,
  ce.created_at,
  ce.updated_at
FROM data.calendar_events ce
WHERE ce.entity_type = 'project'
  AND ce.entity_id = '52000000-0000-0000-0000-000000000001'::uuid
ORDER BY ce.created_at DESC;

SELECT
  COUNT(*) AS notifications_for_project
FROM data.notifications n
WHERE n.related_entity_type = 'project'
  AND n.related_entity_id = '52000000-0000-0000-0000-000000000001'::uuid;

SELECT *
FROM pgmq.metrics('project_events');
