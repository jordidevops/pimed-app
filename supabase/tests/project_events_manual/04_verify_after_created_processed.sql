-- Step 04: Run this after processing the worker once.
-- Expected: notifications created, no calendar event yet (planned_start is NULL).

SELECT
  n.user_id,
  n.kind,
  n.severity,
  n.deep_link,
  n.created_at
FROM data.notifications n
WHERE n.related_entity_type = 'project'
  AND n.related_entity_id = '52000000-0000-0000-0000-000000000001'::uuid
ORDER BY n.created_at DESC;

SELECT
  COUNT(*) AS calendar_events_for_project
FROM data.calendar_events ce
WHERE ce.entity_type = 'project'
  AND ce.entity_id = '52000000-0000-0000-0000-000000000001'::uuid;
