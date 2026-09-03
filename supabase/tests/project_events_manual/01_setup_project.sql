-- Step 01: Reset + create a dedicated project for manual queue testing.
-- Safe to re-run: it deletes previous traces for this fixed project id.

DELETE FROM data.calendar_events
WHERE entity_type = 'project'
  AND entity_id = '52000000-0000-0000-0000-000000000001'::uuid;

DELETE FROM data.notifications
WHERE related_entity_type = 'project'
  AND related_entity_id = '52000000-0000-0000-0000-000000000001'::uuid;

DELETE FROM data.project_members
WHERE project_id = '52000000-0000-0000-0000-000000000001'::uuid;

DELETE FROM data.projects
WHERE id = '52000000-0000-0000-0000-000000000001'::uuid;

DO $$
BEGIN
  IF to_regclass('pgmq.q_project_events') IS NOT NULL THEN
    DELETE FROM pgmq.q_project_events
    WHERE message ->> 'project_id' = '52000000-0000-0000-0000-000000000001';
  END IF;

  IF to_regclass('pgmq.a_project_events') IS NOT NULL THEN
    DELETE FROM pgmq.a_project_events
    WHERE message ->> 'project_id' = '52000000-0000-0000-0000-000000000001';
  END IF;
END
$$;

INSERT INTO data.projects (
  id,
  tenant_id,
  type,
  name,
  description,
  status,
  visibility,
  site_id,
  location_id,
  created_by,
  planned_start,
  planned_end
)
VALUES (
  '52000000-0000-0000-0000-000000000001'::uuid,
  '10000000-0000-0000-0000-000000000001'::uuid,
  'maintenance',
  'Manual Queue Test Project',
  'Projecte de proves pas a pas per project_events.',
  'in_progress',
  'company',
  '30000000-0000-0000-0000-000000000001'::uuid,
  '41000000-0000-0000-0000-000000000002'::uuid,
  '20000000-0000-0000-0000-000000000004'::uuid,
  NULL,
  NULL
);

INSERT INTO data.project_members (project_id, user_id, role)
VALUES
  ('52000000-0000-0000-0000-000000000001'::uuid, '20000000-0000-0000-0000-000000000004'::uuid, 'manager'),
  ('52000000-0000-0000-0000-000000000001'::uuid, '20000000-0000-0000-0000-000000000005'::uuid, 'contributor')
ON CONFLICT (project_id, user_id) DO NOTHING;

SELECT
  p.id,
  p.tenant_id,
  p.site_id,
  p.name,
  p.status,
  p.planned_start,
  p.planned_end
FROM data.projects p
WHERE p.id = '52000000-0000-0000-0000-000000000001'::uuid;
