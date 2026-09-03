-- =============================================================================
-- TASK_ASSIGNED polish — deep link al projecte (tenant-portal: /projects/:id)
-- =============================================================================

UPDATE data.notification_event_catalog
SET deep_link_template = '/projects/{project_id}'
WHERE event_code = 'TASK_ASSIGNED';

COMMENT ON COLUMN data.notification_event_catalog.deep_link_template IS
  'Plantilla de ruta in-app. Placeholders: {entity_id}, {project_id}, {tenant_id}. '
  'TASK_ASSIGNED usa {project_id} (payload.project_id de data.tasks).';
