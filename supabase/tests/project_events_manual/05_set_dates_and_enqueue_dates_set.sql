-- Step 05: Set planned dates and enqueue a date-sync event.
-- Preferred path: PROJECT_DATES_SET (no extra notifications).
-- Fallback path: PROJECT_CREATED with planned_start if the dates RPC is absent.

UPDATE data.projects
SET planned_start = now() + interval '1 day',
    planned_end   = now() + interval '2 days'
WHERE id = '52000000-0000-0000-0000-000000000001'::uuid;

SELECT
  pgmq.send(
    'project_events',
    CASE
      WHEN to_regprocedure('api.handle_project_dates_set_event(uuid,uuid)') IS NOT NULL THEN
        jsonb_build_object(
          'task',
          'PROJECT_DATES_SET',
          'project_id',
          '52000000-0000-0000-0000-000000000001'::uuid,
          'tenant_id',
          '10000000-0000-0000-0000-000000000001'::uuid,
          'idempotency_key',
          'manual-dates-set-52000000-0000-0000-0000-000000000001-' || extract(epoch from now())::bigint
        )
      ELSE
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
          (SELECT planned_start FROM data.projects WHERE id = '52000000-0000-0000-0000-000000000001'::uuid),
          'created_by',
          '20000000-0000-0000-0000-000000000004'::uuid
        )
    END
  ) AS queued_msg_id,
  (to_regprocedure('api.handle_project_dates_set_event(uuid,uuid)') IS NOT NULL) AS using_project_dates_set;

SELECT
  id,
  planned_start,
  planned_end
FROM data.projects
WHERE id = '52000000-0000-0000-0000-000000000001'::uuid;
