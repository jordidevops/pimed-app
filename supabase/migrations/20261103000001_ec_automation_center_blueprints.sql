-- =============================================================================
-- EC Automation Center blueprints
-- Consume EC-8 audit events; rewrite onboarding off EMPLOYEE_CREATED;
-- deactivate daily contract renewal reminder; seed CONTRACT_* blueprints;
-- extend entity snapshot for employment_contract.
-- =============================================================================

-- =============================================================================
-- 1. Temporary upsert helper (match by is_blueprint + name + tenant_id IS NULL)
-- =============================================================================

CREATE OR REPLACE FUNCTION data.upsert_platform_blueprint(
  p_name         text,
  p_description  text,
  p_trigger_event text,
  p_trigger_filters jsonb,
  p_steps        jsonb
)
RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
  v_id uuid;
BEGIN
  SELECT id INTO v_id
  FROM data.automation_workflows
  WHERE is_blueprint = true AND name = p_name AND tenant_id IS NULL;

  IF FOUND THEN
    UPDATE data.automation_workflows
    SET description     = p_description,
        trigger_event   = p_trigger_event,
        trigger_filters = p_trigger_filters,
        steps           = p_steps,
        version         = version + 1,
        updated_at      = now()
    WHERE id = v_id;
  ELSE
    INSERT INTO data.automation_workflows (
      name, description, trigger_event, trigger_filters, steps,
      is_blueprint, is_active, tenant_id
    ) VALUES (
      p_name, p_description, p_trigger_event, p_trigger_filters, p_steps,
      true, true, NULL
    )
    RETURNING id INTO v_id;
  END IF;

  RETURN v_id;
END;
$$;


-- =============================================================================
-- 2. Rewrite: Onboarding d'empleats
-- Trigger: EMPLOYEE_LIFECYCLE_CHANGED when to=active
-- Steps: SEND_EMAIL welcome + CREATE_CALENDAR_EVENT only
-- =============================================================================

SELECT data.upsert_platform_blueprint(
  'Onboarding d''empleats',
  'Envia benvinguda quan el lifecycle de l''empleat passa a active; el contracte es gestiona a EC, no aquí.',
  'EMPLOYEE_LIFECYCLE_CHANGED',
  '{"to": "active"}'::jsonb,
  '[
    {
      "id": "step_1",
      "name": "Email de benvinguda",
      "type": "SEND_EMAIL",
      "config": {
        "recipient_source": "fixed",
        "recipients": ["{{ entity.email }}"],
        "event_type": "employee_onboarding_welcome",
        "template_variables": {
          "employee_name": "{{ entity.full_name }}",
          "starts_on": "{{ entity.starts_on }}"
        }
      },
      "on_success": "step_2",
      "on_failure": "step_2",
      "retry_max": 2
    },
    {
      "id": "step_2",
      "name": "Crear event primer dia",
      "type": "CREATE_CALENDAR_EVENT",
      "config": {
        "title": "Primer dia laboral - {{ entity.full_name }}",
        "description": "Sessió d''incorporació de {{ entity.full_name }} (starts_on: {{ entity.starts_on }} / {{ entity.start_date }})",
        "start_at_template": "{{ entity.starts_on }}",
        "all_day": true
      },
      "on_success": "END_OK",
      "on_failure": "END_OK"
    }
  ]'::jsonb
);


-- =============================================================================
-- 3. Deactivate: Recordatori renovació de contractes (superseded by CONTRACT_EXPIRING)
-- =============================================================================

UPDATE data.automation_workflows
SET is_active = false,
    description = 'Desactivat: supersedit pel blueprint Contracte — a punt de vèncer (CONTRACT_EXPIRING). No s''esborra perquè els tenants poden tenir clons.',
    updated_at = now(),
    version = version + 1
WHERE is_blueprint = true
  AND tenant_id IS NULL
  AND name = 'Recordatori renovació de contractes';


-- =============================================================================
-- 4A. Contracte — activació bloquejada
-- =============================================================================

SELECT data.upsert_platform_blueprint(
  'Contracte — activació bloquejada',
  'Quan l''activació d''un contracte queda bloquejada (p. ex. signatura), notifica el manager i crea una tasca de seguiment.',
  'CONTRACT_ACTIVATION_BLOCKED',
  '{}'::jsonb,
  '[
    {
      "id": "step_1",
      "name": "Notificar manager",
      "type": "SEND_NOTIFICATION",
      "config": {
        "event_type": "CONTRACT_ACTIVATION_BLOCKED",
        "recipient_role": "manager"
      },
      "on_success": "step_2",
      "on_failure": "step_2"
    },
    {
      "id": "step_2",
      "name": "Tasca activació bloquejada",
      "type": "CREATE_TASK",
      "config": {
        "title": "Activació de contracte bloquejada — {{ entity.full_name }} ({{ entity.contract_number }})",
        "description": "Revisar signatura / requisits per activar el contracte {{ entity.contract_number }}.",
        "assignee_role": "manager"
      },
      "on_success": "END_OK",
      "on_failure": "END_OK"
    }
  ]'::jsonb
);


-- =============================================================================
-- 4B. Contracte — a punt de vèncer
-- =============================================================================

SELECT data.upsert_platform_blueprint(
  'Contracte — a punt de vèncer',
  'Quan un contracte s''aproxima al venciment (CONTRACT_EXPIRING), notifica el manager i crea tasca de renovació.',
  'CONTRACT_EXPIRING',
  '{}'::jsonb,
  '[
    {
      "id": "step_1",
      "name": "Notificar manager",
      "type": "SEND_NOTIFICATION",
      "config": {
        "event_type": "CONTRACT_EXPIRING",
        "recipient_role": "manager"
      },
      "on_success": "step_2",
      "on_failure": "step_2"
    },
    {
      "id": "step_2",
      "name": "Tasca seguiment renovació",
      "type": "CREATE_TASK",
      "config": {
        "title": "Renovació de contracte — {{ entity.full_name }} (vencèncer {{ entity.ends_on }})",
        "description": "Fer seguiment de la renovació del contracte {{ entity.contract_number }}.",
        "assignee_role": "manager"
      },
      "on_success": "END_OK",
      "on_failure": "END_OK"
    }
  ]'::jsonb
);


-- =============================================================================
-- 4C. Contracte — activat
-- =============================================================================

SELECT data.upsert_platform_blueprint(
  'Contracte — activat',
  'Quan un contracte s''activa, crea un event de calendari del primer dia i envia email de benvinguda si hi ha email.',
  'CONTRACT_ACTIVATED',
  '{}'::jsonb,
  '[
    {
      "id": "step_1",
      "name": "Event primer dia / contracte activat",
      "type": "CREATE_CALENDAR_EVENT",
      "config": {
        "title": "Primer dia / contracte activat — {{ entity.full_name }}",
        "description": "Contracte {{ entity.contract_number }} activat (starts_on: {{ entity.starts_on }}).",
        "start_at_template": "{{ entity.starts_on }}",
        "all_day": true
      },
      "on_success": "step_2",
      "on_failure": "step_2"
    },
    {
      "id": "step_2",
      "name": "Email benvinguda contracte activat",
      "type": "SEND_EMAIL",
      "config": {
        "recipient_source": "fixed",
        "recipients": ["{{ entity.email }}"],
        "event_type": "employment_contract_activated_welcome",
        "template_variables": {
          "employee_name": "{{ entity.full_name }}",
          "contract_number": "{{ entity.contract_number }}",
          "starts_on": "{{ entity.starts_on }}"
        }
      },
      "on_success": "END_OK",
      "on_failure": "END_OK",
      "retry_max": 2
    }
  ]'::jsonb
);


-- =============================================================================
-- 4D. Contracte — finalitzat
-- =============================================================================

SELECT data.upsert_platform_blueprint(
  'Contracte — finalitzat',
  'Quan un contracte finalitza (CONTRACT_ENDED), notifica el manager i crea una tasca de tancament.',
  'CONTRACT_ENDED',
  '{}'::jsonb,
  '[
    {
      "id": "step_1",
      "name": "Notificar manager",
      "type": "SEND_NOTIFICATION",
      "config": {
        "event_type": "CONTRACT_ENDED",
        "recipient_role": "manager"
      },
      "on_success": "step_2",
      "on_failure": "step_2"
    },
    {
      "id": "step_2",
      "name": "Tasca contracte finalitzat",
      "type": "CREATE_TASK",
      "config": {
        "title": "Contracte finalitzat — {{ entity.full_name }} ({{ entity.contract_number }})",
        "description": "Revisar tancament / offboarding del contracte {{ entity.contract_number }} (ends_on: {{ entity.ends_on }}).",
        "assignee_role": "manager"
      },
      "on_success": "END_OK",
      "on_failure": "END_OK"
    }
  ]'::jsonb
);


-- =============================================================================
-- 5. Extend entity snapshot for employment_contract (if function exists)
-- =============================================================================

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api'
      AND p.proname = 'get_entity_snapshot_for_automation'
  ) THEN
    EXECUTE $fn$
CREATE OR REPLACE FUNCTION api.get_entity_snapshot_for_automation(
  p_tenant_id   uuid,
  p_entity_type text,
  p_entity_id   uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $body$
DECLARE
  v_row jsonb;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF p_entity_type = 'contact' THEN
    SELECT to_jsonb(c) INTO v_row
    FROM (
      SELECT id, tenant_id, site_id, kind, display_name, given_name, family_name,
             email, phone, tags, metadata, owner_user_id
      FROM data.contacts
      WHERE id = p_entity_id AND tenant_id = p_tenant_id
    ) c;

  ELSIF p_entity_type = 'employee' THEN
    SELECT to_jsonb(e) INTO v_row
    FROM (
      SELECT id, tenant_id, site_id, user_id, full_name, email, phone,
             job_title, status, starts_on, ends_on, metadata
      FROM data.employees
      WHERE id = p_entity_id AND tenant_id = p_tenant_id
    ) e;

  ELSIF p_entity_type = 'document' THEN
    SELECT to_jsonb(d) INTO v_row
    FROM (
      SELECT id, tenant_id, site_id, folder_id, title, entity_type, entity_id,
             approval_status, approved_by, approved_at
      FROM data.documents
      WHERE id = p_entity_id AND tenant_id = p_tenant_id
    ) d;

  ELSIF p_entity_type IN ('employment_contract', 'employment_contracts') THEN
    SELECT to_jsonb(ec) INTO v_row
    FROM (
      SELECT
        c.id,
        c.employee_id,
        c.contract_number,
        c.starts_on,
        c.ends_on,
        c.lifecycle_status,
        COALESCE(c.site_id, e.site_id) AS site_id,
        e.full_name,
        e.email
      FROM data.employment_contracts c
      LEFT JOIN data.employees e
        ON e.id = c.employee_id AND e.tenant_id = c.tenant_id
      WHERE c.id = p_entity_id AND c.tenant_id = p_tenant_id
    ) ec;

  ELSE
    RETURN '{}'::jsonb;
  END IF;

  RETURN COALESCE(v_row, '{}'::jsonb);
END;
$body$;
$fn$;

    REVOKE ALL ON FUNCTION api.get_entity_snapshot_for_automation(uuid, text, uuid) FROM PUBLIC;
    GRANT EXECUTE ON FUNCTION api.get_entity_snapshot_for_automation(uuid, text, uuid) TO service_role;
  END IF;
END $$;


-- =============================================================================
-- 6. Drop temporary helper
-- =============================================================================

DROP FUNCTION IF EXISTS data.upsert_platform_blueprint(text, text, text, jsonb, jsonb);


-- =============================================================================
-- 7. NOTIFY
-- =============================================================================

NOTIFY pgrst, 'reload schema';
