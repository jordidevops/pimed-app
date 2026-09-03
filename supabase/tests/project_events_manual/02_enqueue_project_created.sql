-- Step 02: Enqueue PROJECT_CREATED in legacy format (`event` field, no `task`).
-- This validates QueueRunner defaultTask fallback.

SELECT pgmq.send(
  'project_events',
  jsonb_build_object(
    'event',
    'PROJECT_CREATED',
    'project_id',
    '52000000-0000-0000-0000-000000000001'::uuid,
    'tenant_id',
    '10000000-0000-0000-0000-000000000001'::uuid,
    'name',
    'Manual Queue Test Project',
    'type',
    'maintenance',
    'planned_start',
    NULL,
    'created_by',
    '20000000-0000-0000-0000-000000000004'::uuid
  )
) AS queued_msg_id;
