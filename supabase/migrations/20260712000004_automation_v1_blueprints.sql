-- =============================================================================
-- Automation Engine V1 — Blueprints de plataforma
-- Catàleg inicial de blueprints instal·lables pels tenants.
--
-- Depèn de: 20260712000001_automation_v1_core.sql
-- =============================================================================

-- =============================================================================
-- 1. Funció helper per inserir/actualitzar blueprints de forma idempotent
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
-- 2. Blueprint: Onboarding d'empleats
-- Trigger: EMPLOYEE_CREATED
-- Steps: Generar contracte → Aprovació manager → Enviar a signar →
--        Email benvinguda → Crear event calendari
-- =============================================================================

SELECT data.upsert_platform_blueprint(
  'Onboarding d''empleats',
  'Automatitza el procés d''incorporació d''un nou empleat: generació del contracte, aprovació, signatura, email de benvinguda i creació de l''event al calendari.',
  'EMPLOYEE_CREATED',
  '{}'::jsonb,
  '[
    {
      "id": "step_1",
      "name": "Generar contracte laboral",
      "type": "GENERATE_DOCUMENT",
      "config": {
        "template_id": "{{ config.contract_template_id }}",
        "folder_id": "{{ config.contracts_folder_id }}"
      },
      "on_success": "step_2",
      "on_failure": "END_FAIL",
      "retry_max": 2,
      "timeout_minutes": 5
    },
    {
      "id": "step_2",
      "name": "Aprovació manager",
      "type": "HUMAN_APPROVAL",
      "config": {
        "assigned_to_role": "manager",
        "context_preview_fields": ["entity.full_name", "entity.email", "entity.department_id"],
        "due_hours": 48
      },
      "on_success": "step_3",
      "on_failure": "END_FAIL"
    },
    {
      "id": "step_3",
      "name": "Enviar contracte a signar",
      "type": "SEND_FOR_SIGNING",
      "config": {
        "document_id_template": "{{ steps.step_1.output.document_id }}"
      },
      "on_success": "step_4",
      "on_failure": "END_FAIL",
      "retry_max": 2
    },
    {
      "id": "step_4",
      "name": "Email de benvinguda",
      "type": "SEND_EMAIL",
      "config": {
        "recipient_source": "fixed",
        "recipients": ["{{ entity.email }}"],
        "event_type": "employee_onboarding_welcome",
        "template_variables": {
          "employee_name": "{{ entity.full_name }}"
        }
      },
      "on_success": "step_5",
      "on_failure": "step_5",
      "retry_max": 2
    },
    {
      "id": "step_5",
      "name": "Crear event primer dia",
      "type": "CREATE_CALENDAR_EVENT",
      "config": {
        "title": "Primer dia laboral — {{ entity.full_name }}",
        "description": "Sessió d''incorporació de {{ entity.full_name }}",
        "start_at_template": "{{ entity.start_date }}",
        "all_day": true
      },
      "on_success": "END_OK",
      "on_failure": "END_OK"
    }
  ]'::jsonb
);


-- =============================================================================
-- 3. Blueprint: Alta de client / lead
-- Trigger: CONTACT_CREATED
-- Steps: Email de benvinguda → Crear tasca comercial → Notificació manager
-- =============================================================================

SELECT data.upsert_platform_blueprint(
  'Alta de client / lead',
  'Quan es crea un nou contacte o lead, envia un email de benvinguda, crea una tasca de seguiment i notifica el responsable comercial.',
  'CONTACT_CREATED',
  '{}'::jsonb,
  '[
    {
      "id": "step_1",
      "name": "Email de benvinguda",
      "type": "SEND_EMAIL",
      "config": {
        "recipient_source": "fixed",
        "recipients": ["{{ entity.email }}"],
        "event_type": "contact_welcome",
        "template_variables": {
          "contact_name": "{{ entity.full_name }}"
        }
      },
      "on_success": "step_2",
      "on_failure": "step_2",
      "retry_max": 2
    },
    {
      "id": "step_2",
      "name": "Crear tasca de seguiment",
      "type": "CREATE_TASK",
      "config": {
        "title": "Seguiment nou client: {{ entity.full_name }}",
        "description": "Client creat el {{ trigger.timestamp }}",
        "assignee_role": "manager"
      },
      "on_success": "step_3",
      "on_failure": "step_3"
    },
    {
      "id": "step_3",
      "name": "Notificar responsable",
      "type": "SEND_NOTIFICATION",
      "config": {
        "event_type": "NEW_CONTACT_CREATED",
        "recipient_role": "manager"
      },
      "on_success": "END_OK",
      "on_failure": "END_OK"
    }
  ]'::jsonb
);


-- =============================================================================
-- 4. Blueprint: Renovació de contractes (recordatori)
-- Trigger: SCHEDULED_DAILY
-- Steps: Email avís renovació → Crear tasca RRHH
-- =============================================================================

SELECT data.upsert_platform_blueprint(
  'Recordatori renovació de contractes',
  'Enviament diari d''alertes de venciment de contractes als responsables de RRHH amb tasca de seguiment.',
  'SCHEDULED_DAILY',
  '{}'::jsonb,
  '[
    {
      "id": "step_1",
      "name": "Email avís renovació",
      "type": "SEND_EMAIL",
      "config": {
        "recipient_source": "fixed",
        "recipients": ["{{ config.hr_manager_email }}"],
        "event_type": "contract_renewal_reminder",
        "template_variables": {}
      },
      "on_success": "step_2",
      "on_failure": "END_FAIL",
      "retry_max": 2
    },
    {
      "id": "step_2",
      "name": "Crear tasca de gestió",
      "type": "CREATE_TASK",
      "config": {
        "title": "Revisar contractes per vèncer el proper mes",
        "description": "Tasca generada automàticament pel sistema d''alertes de venciment.",
        "assignee_role": "manager"
      },
      "on_success": "END_OK",
      "on_failure": "END_OK"
    }
  ]'::jsonb
);


-- =============================================================================
-- 5. Blueprint: Signatura completada
-- Trigger: DOCUMENT_SIGNED
-- Steps: Email confirmació → Notificació manager
-- =============================================================================

SELECT data.upsert_platform_blueprint(
  'Signatura completada',
  'Quan un document és signat per totes les parts, envia un email de confirmació als signataris i notifica el manager responsable.',
  'DOCUMENT_SIGNED',
  '{}'::jsonb,
  '[
    {
      "id": "step_1",
      "name": "Email confirmació als signataris",
      "type": "SEND_EMAIL",
      "config": {
        "recipient_source": "fixed",
        "recipients": ["{{ entity.signer_email }}"],
        "event_type": "document_signed_confirmation",
        "template_variables": {
          "document_title": "{{ entity.title }}"
        }
      },
      "on_success": "step_2",
      "on_failure": "step_2",
      "retry_max": 2
    },
    {
      "id": "step_2",
      "name": "Notificar manager",
      "type": "SEND_NOTIFICATION",
      "config": {
        "event_type": "DOCUMENT_SIGNATURE_COMPLETED",
        "recipient_role": "manager"
      },
      "on_success": "END_OK",
      "on_failure": "END_OK"
    }
  ]'::jsonb
);


-- =============================================================================
-- 6. Blueprint: Gestió de vacances / absències
-- Trigger: ABSENCE_REQUESTED
-- Steps: Notificació manager → Aprovació → Notificació empleat
-- =============================================================================

SELECT data.upsert_platform_blueprint(
  'Gestió de sol·licituds d''absència',
  'Quan un empleat sol·licita vacances o absència, notifica el manager, espera la seva aprovació i notifica l''empleat del resultat.',
  'ABSENCE_REQUESTED',
  '{}'::jsonb,
  '[
    {
      "id": "step_1",
      "name": "Notificar manager",
      "type": "SEND_NOTIFICATION",
      "config": {
        "event_type": "ABSENCE_APPROVAL_REQUIRED",
        "recipient_role": "manager"
      },
      "on_success": "step_2",
      "on_failure": "step_2"
    },
    {
      "id": "step_2",
      "name": "Aprovació manager",
      "type": "HUMAN_APPROVAL",
      "config": {
        "assigned_to_role": "manager",
        "context_preview_fields": ["entity.full_name", "entity.start_date", "entity.end_date"],
        "due_hours": 72
      },
      "on_success": "step_3_approved",
      "on_failure": "step_3_rejected"
    },
    {
      "id": "step_3_approved",
      "name": "Notificar empleat — Aprovada",
      "type": "SEND_NOTIFICATION",
      "config": {
        "event_type": "ABSENCE_APPROVED",
        "recipient_user_id": "{{ entity.employee_id }}"
      },
      "on_success": "END_OK",
      "on_failure": "END_OK"
    },
    {
      "id": "step_3_rejected",
      "name": "Notificar empleat — Rebutjada",
      "type": "SEND_NOTIFICATION",
      "config": {
        "event_type": "ABSENCE_REJECTED",
        "recipient_user_id": "{{ entity.employee_id }}"
      },
      "on_success": "END_OK",
      "on_failure": "END_OK"
    }
  ]'::jsonb
);


-- =============================================================================
-- 7. Neteja de la funció helper temporal
-- =============================================================================

DROP FUNCTION IF EXISTS data.upsert_platform_blueprint(text, text, text, jsonb, jsonb);


-- =============================================================================
-- 8. NOTIFY
-- =============================================================================

NOTIFY pgrst, 'reload schema';
